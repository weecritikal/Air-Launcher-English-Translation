#import "DownloadViewController.h"
#import "BackgroundManager.h"
// UIImageView+AFNetworking：为 ModernAssetCell 提供 setImageWithURL:placeholderImage:，
// 自带内存+磁盘缓存，比手动 NSData 下载更高效，且能复用同一 URL 的下载任务
#import "UIImageView+AFNetworking.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "InlineMessageView.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "PLPreferences.h"
#import "ModService.h"
#import "ShaderService.h"
#import "ResourcePackService.h"
#import "DataPackService.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "VersionCardCell.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressViewController.h"
#import "ModItem.h"
#import "ModVersionViewController.h"
#import "ModVersion.h"
#import "ShaderItem.h"
#import "ShaderVersionViewController.h"
#import "ShaderVersion.h"
#import "ResourcePackItem.h"
#import "DataPackItem.h"
#import "WorldItem.h"
#import "AssetVersionViewController.h"
#import "WorldService.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "installer/NeoForgeVersionFetcher.h"
#import "installer/ModLoaderInstallViewController.h"
#import "LauncherNavigationController.h"
#import "installer/ModpackInstallViewController.h"
#import "ModpackImportViewController.h"
#import "ModpackImportService.h"
#import "installer/CurseForgeAPIKeyViewController.h"
#import "ServerListViewController.h"
#import "ServerDetailViewController.h"
#import "ServerService.h"
#import "ServerItem.h"
#import "UZKArchive.h"
#import <QuartzCore/QuartzCore.h>
#import "JavaGUIViewController.h"
#import "utils.h"
#import "ios_uikit_bridge.h"
#import "ALTServerConnection.h"
#import "ModLoaderIconHelper.h"

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

#pragma mark - Modern Asset Cell

// 资源类型枚举：决定占位图标与配色，区分 6 类资源（mod/shader/resourcepack/datapack/world/modpack）
// 参照 FCL CategoryBox 与 ZL2 AddonListLayout 的图标体系，使用 SF Symbols 替代项目自有 PNG
typedef NS_ENUM(NSInteger, ModernAssetType) {
    ModernAssetTypeMod = 0,           // 模组：puzzlepiece.fill + 橙
    ModernAssetTypeShader,            // 光影：paintbrush.fill + 紫
    ModernAssetTypeResourcepack,      // 资源包：photo.stack.fill + 蓝
    ModernAssetTypeDatapack,          // 数据包：doc.text.fill + 青
    ModernAssetTypeWorld,             // 世界：globe.asia.australia.fill + 绿
    ModernAssetTypeModpack            // 整合包：shippingbox.fill + 粉
};

@interface ModernAssetCell : UITableViewCell
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIStackView *tagsStack;
@property (nonatomic, strong) UIButton *downloadButton;
// 当前资源类型（用于在 prepareForReuse 时重置占位图标与配色）
@property (nonatomic, assign) ModernAssetType assetType;
// 缓存当前正在加载图片的 URL，避免复用时旧请求覆盖新请求（cell 复用竞态）
@property (nonatomic, copy, nullable) NSString *currentIconURL;
@end

@implementation ModernAssetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.assetType = ModernAssetTypeMod;

        // ----- 卡片容器：圆角 + 半透明背景 + 浅阴影（参照 FCL bg_container_white + ZL2 Surface cardColor）-----
        // 替代原来直接 addSubview 到 contentView 的扁平布局，统一与 VersionCardCell 一致的视觉规范
        self.contentContainer = [[UIView alloc] init];
        self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        self.contentContainer.layer.cornerRadius = 16;
        self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.contentContainer.layer.borderWidth = 0.5;
        self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.contentContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        self.contentContainer.layer.shadowOffset = CGSizeMake(0, 4);
        self.contentContainer.layer.shadowOpacity = 0.12;
        self.contentContainer.layer.shadowRadius = 8;
        [self.contentView addSubview:self.contentContainer];

        // ----- 左侧图标：56x56 圆角，承载资源主图（项目 icon 或占位 SF Symbol）-----
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 12;
        self.iconView.layer.cornerCurve = kCACornerCurveContinuous;
        self.iconView.clipsToBounds = YES;
        // 默认背景：浅灰色圆角方块，图标加载前给一个视觉占位（FCL/ZL2 风格）
        self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = [UIColor systemOrangeColor];
        [self.contentContainer addSubview:self.iconView];

        // ----- 标题 -----
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.numberOfLines = 1;
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.7;
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentContainer addSubview:self.titleLabel];

        // ----- 描述（最多 2 行）-----
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 2;
        self.descLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentContainer addSubview:self.descLabel];

        // ----- 元信息：作者 • 下载量 • 更新日期 -----
        self.metaLabel = [[UILabel alloc] init];
        self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.metaLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        self.metaLabel.textColor = [UIColor tertiaryLabelColor];
        self.metaLabel.numberOfLines = 1;
        self.metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentContainer addSubview:self.metaLabel];

        // ----- 标签 stack：水平排列，最多 3 个，自动按 loader/类别配色 -----
        self.tagsStack = [[UIStackView alloc] init];
        self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
        self.tagsStack.spacing = 6;
        self.tagsStack.distribution = UIStackViewDistributionFill;
        self.tagsStack.alignment = UIStackViewAlignmentCenter;
        [self.contentContainer addSubview:self.tagsStack];

        // ----- 下载按钮（圆形图标按钮，FCL 风格）-----
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        // 用 UIImageSymbolConfiguration 控制图标大小（iOS 13+），回退到普通 setImage
        UIImage *downloadSymbol = [UIImage systemImageNamed:@"arrow.down.circle.fill"
                                          withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIFontWeightRegular]];
        if (!downloadSymbol) {
            downloadSymbol = [UIImage systemImageNamed:@"arrow.down.circle.fill"];
        }
        [self.downloadButton setImage:downloadSymbol forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        // 按下反馈：缩小动画（FCL anim_scale）
        self.downloadButton.showsTouchWhenHighlighted = NO;
        [self.downloadButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.downloadButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.contentContainer addSubview:self.downloadButton];

        [NSLayoutConstraint activateConstraints:@[
            // 卡片容器充满 contentView，上下留 6pt 间距作为行间分隔
            [self.contentContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],

            // 图标：左 14，垂直居中，56x56
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:14],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:56],
            [self.iconView.heightAnchor constraintEqualToConstant:56],

            // 标题：紧跟图标右侧 +12，顶部对齐图标顶部，右侧留出下载按钮空间
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.topAnchor],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-8],

            // 描述：与标题左对齐，紧跟标题下方 +2
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.descLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

            // 元信息：紧跟描述下方 +2
            [self.metaLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.metaLabel.topAnchor constraintEqualToAnchor:self.descLabel.bottomAnchor constant:2],
            [self.metaLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],

            // 标签 stack：紧跟元信息下方 +4
            [self.tagsStack.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.tagsStack.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:4],
            [self.tagsStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-8],
            [self.tagsStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-10],

            // 下载按钮：右侧 -14，垂直居中，40x40
            [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-14],
            [self.downloadButton.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.downloadButton.widthAnchor constraintEqualToConstant:40],
            [self.downloadButton.heightAnchor constraintEqualToConstant:40]
        ]];

        // 应用毛玻璃背景效果（BackgroundManager 统一管理深浅色与模糊度）
        [[BackgroundManager sharedManager] applyEffectToView:self.contentContainer];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 重置图标状态：避免复用时旧图残留导致显示错乱
    self.iconView.image = nil;
    self.iconView.tintColor = [UIColor systemOrangeColor];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    self.currentIconURL = nil;
    // 移除所有标签
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    // 重置下载按钮 target（防止复用后旧 target 残留触发错误下载）
    [self.downloadButton removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
}

#pragma mark - 占位图标与配色（按资源类型）

/// 根据资源类型返回默认占位 SF Symbol 名称
- (NSString *)placeholderIconNameForType:(ModernAssetType)type {
    switch (type) {
        case ModernAssetTypeMod:          return @"puzzlepiece.fill";
        case ModernAssetTypeShader:       return @"paintbrush.fill";
        case ModernAssetTypeResourcepack: return @"photo.stack.fill";
        case ModernAssetTypeDatapack:     return @"doc.text.fill";
        case ModernAssetTypeWorld:        return @"globe.asia.australia.fill";
        case ModernAssetTypeModpack:      return @"shippingbox.fill";
    }
    return @"puzzlepiece.fill";
}

/// 根据资源类型返回占位图标主色（用作 iconView.tintColor，与 FCL/ZL2 各资源类型的视觉色一致）
- (UIColor *)placeholderColorForType:(ModernAssetType)type {
    switch (type) {
        case ModernAssetTypeMod:          return [UIColor systemOrangeColor];
        case ModernAssetTypeShader:       return [UIColor systemPurpleColor];
        case ModernAssetTypeResourcepack: return [UIColor systemBlueColor];
        case ModernAssetTypeDatapack:     return [UIColor systemTealColor];
        case ModernAssetTypeWorld:        return [UIColor systemGreenColor];
        case ModernAssetTypeModpack:      return [UIColor systemPinkColor];
    }
    return [UIColor systemOrangeColor];
}

/// 应用占位图标：先显示类型对应的 SF Symbol，等异步加载完成后替换为项目图标
- (void)applyPlaceholderIconForType:(ModernAssetType)type {
    NSString *iconName = [self placeholderIconNameForType:type];
    UIColor *iconColor = [self placeholderColorForType:type];
    UIImage *symbol = [UIImage systemImageNamed:iconName];
    if (symbol) {
        self.iconView.image = symbol;
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
    }
    self.iconView.tintColor = iconColor;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
}

#pragma mark - 通用配置辅助

/// 格式化下载量数字：1234 → "1.2K"，1234567 → "1.2M"
- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) {
        return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    } else if (dl >= 1000) {
        return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    } else {
        return [NSString stringWithFormat:@"%ld", (long)dl];
    }
}

/// 格式化日期字符串："2024-01-15T12:34:56Z" → "2024-01-15"，失败返回空串
- (NSString *)formatDateString:(NSString *)dateString {
    if (![dateString isKindOfClass:[NSString class]] || dateString.length < 10) return @"";
    return [dateString substringToIndex:10];
}

/// 异步加载项目图标：优先用 AFNetworking（带缓存），回退到 NSData
- (void)loadIconFromURL:(NSString *)iconUrl placeholderType:(ModernAssetType)type {
    // 先显示占位图标
    [self applyPlaceholderIconForType:type];

    if (![iconUrl isKindOfClass:[NSString class]] || iconUrl.length == 0) {
        return;
    }

    // 记录当前正在加载的 URL，防止 cell 复用后旧请求覆盖新请求
    self.currentIconURL = [iconUrl copy];

    __weak typeof(self) weakSelf = self;
    void (^applyImage)(UIImage *) = ^(UIImage *image) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !image) return;
        // 校验：cell 复用后 currentIconURL 可能已变，避免旧图覆盖新 cell
        if (![strongSelf.currentIconURL isEqualToString:iconUrl]) return;
        strongSelf.iconView.contentMode = UIViewContentModeScaleAspectFill;
        strongSelf.iconView.image = image;
        strongSelf.iconView.tintColor = [UIColor clearColor];
    };

    // 优先用 AFNetworking（自带内存+磁盘缓存，命中率高，且能复用同一 URL 的下载任务）
    if ([self.iconView respondsToSelector:@selector(setImageWithURL:placeholderImage:)]) {
        UIImage *placeholder = self.iconView.image; // 保留当前占位 SF Symbol 作为加载期间显示
        [self.iconView setImageWithURL:[NSURL URLWithString:iconUrl] placeholderImage:placeholder];
        return;
    }

    // 回退：手动 NSData 下载
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]
                                              options:NSDataReadingUncached
                                                error:nil];
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            applyImage(image);
        });
    });
}

/// 配置标签 stack：从 categories 数组取最多 3 个，按 loader/类别配色
/// 参照 ZL2 LittleTextLabel：mod loader 用品牌色，普通类别用中性色
- (void)configureTagsWithCategories:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    if (![categories isKindOfClass:[NSArray class]]) return;

    for (NSInteger i = 0; i < MIN(3, categories.count); i++) {
        id catObj = categories[i];
        NSString *cat = nil;
        if ([catObj isKindOfClass:[NSString class]]) {
            cat = catObj;
        } else if ([catObj isKindOfClass:[NSDictionary class]]) {
            // CurseForge 的 categories 是 dict，取 name 字段
            cat = catObj[@"name"];
        }
        if (![cat isKindOfClass:[NSString class]] || cat.length == 0) continue;

        UILabel *tag = [self createTagLabel:cat];
        [self.tagsStack addArrangedSubview:tag];
    }
}

/// 根据类别名返回配色：加载器品牌色统一委托 ModLoaderIconHelper，类别色保持本地映射
- (UIColor *)colorForCategory:(NSString *)category {
    NSString *lower = category.lowercaseString;
    // 加载器品牌色：统一委托 ModLoaderIconHelper（优先 PNG 图标的官方配色）
    if ([ModLoaderIconHelper isKnownLoader:category]) {
        return [ModLoaderIconHelper brandColorForLoader:category];
    }
    // 常见模组类别配色
    if ([lower containsString:@"magic"])     return [UIColor systemPurpleColor];
    if ([lower containsString:@"tech"])      return [UIColor systemOrangeColor];
    if ([lower containsString:@"adventure"]) return [UIColor systemTealColor];
    if ([lower containsString:@"decoration"]) return [UIColor systemPinkColor];
    if ([lower containsString:@"utility"])   return [UIColor systemBlueColor];
    if ([lower containsString:@"world"])     return [UIColor systemGreenColor];
    // 兜底
    return [UIColor tertiaryLabelColor];
}

- (UILabel *)createTagLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [self colorForCategory:text];
    label.layer.cornerRadius = 8;
    label.layer.cornerCurve = kCACornerCurveContinuous;
    label.layer.masksToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    // 用 autolayout 而非 sizeToFit+frame：前者能正确响应 stackView 的 fill 分布
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    // 内边距：左右 8，上下 2
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.heightAnchor constraintEqualToConstant:18]
    ]];
    // 通过 sizeToFit 算出文字宽度，再加 padding 作为 widthAnchor 约束
    [label sizeToFit];
    CGFloat textWidth = label.frame.size.width;
    [label.widthAnchor constraintEqualToConstant:textWidth + 12].active = YES;
    return label;
}

#pragma mark - 各资源类型配置入口

- (void)configureWithMod:(NSDictionary *)mod {
    self.assetType = ModernAssetTypeMod;
    [self configureCommonWithData:mod type:ModernAssetTypeMod];
}

- (void)configureWithShader:(NSDictionary *)shader {
    self.assetType = ModernAssetTypeShader;
    [self configureCommonWithData:shader type:ModernAssetTypeShader];
}

- (void)configureWithResourcepack:(NSDictionary *)resourcepack {
    self.assetType = ModernAssetTypeResourcepack;
    [self configureCommonWithData:resourcepack type:ModernAssetTypeResourcepack];
}

- (void)configureWithDatapack:(NSDictionary *)datapack {
    self.assetType = ModernAssetTypeDatapack;
    [self configureCommonWithData:datapack type:ModernAssetTypeDatapack];
}

- (void)configureWithWorld:(NSDictionary *)world {
    self.assetType = ModernAssetTypeWorld;
    [self configureCommonWithData:world type:ModernAssetTypeWorld];
}

- (void)configureWithModpack:(NSDictionary *)modpack {
    self.assetType = ModernAssetTypeModpack;
    [self configureCommonWithData:modpack type:ModernAssetTypeModpack];
}

/// 6 类资源共用的配置逻辑：标题/描述/元信息/图标/标签
- (void)configureCommonWithData:(NSDictionary *)data type:(ModernAssetType)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";

    // 元信息：作者 • 下载量 • 更新日期（参照 ZL2 行布局的摘要展示）
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    NSString *updatedDate = [self formatDateString:data[@"lastUpdated"]];

    NSMutableString *meta = [NSMutableString string];
    [meta appendString:author];
    [meta appendString:@"  •  "];
    [meta appendFormat:@"%@ 下载", downloadsStr];
    if (updatedDate.length > 0) {
        [meta appendString:@"  •  更新 "];
        [meta appendString:updatedDate];
    }
    self.metaLabel.text = meta;

    // 图标：先占位，再异步加载项目图标
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    [self loadIconFromURL:iconUrl placeholderType:type];

    // 标签
    [self configureTagsWithCategories:data[@"categories"]];
}

@end

// LoaderCell 与 LoaderSelectionViewController 已迁移至 installer/ModLoaderInstallViewController.m
// 参照 FCL (FoldCraftLauncher) 的 InstallerListPage + VersionInstallInfoPage 重构


#pragma mark - Installer Progress View Controller (FCL 风格进度展示)

@interface InstallerProgressViewController : UIViewController
// 进度 0.0~1.0；<0 表示不确定模式（仅显示转圈，用于无法测算进度的网络请求阶段）
@property (nonatomic, assign) double progress;
@property (nonatomic, copy, nullable) NSString *stageMessage;
@property (nonatomic, copy, nullable) NSString *titleText;
@property (nonatomic, copy, nullable) void (^cancelHandler)(void);
@end

@interface InstallerProgressViewController ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic, strong) UILabel *stageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *indeterminateIndicator;
@end

@implementation InstallerProgressViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 适配自定义启动器背景（参照 ForgeInstallViewController）
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 取消按钮（替代返回按钮，避免误以为已完成）
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                          target:self
                                                                                          action:@selector(cancelTapped)];
    self.navigationItem.hidesBackButton = YES;

    [self setupUI];
    [self updateUI];
}

- (void)refreshBackgroundEffect {
    // 透明背景下无需额外操作
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    self.cardView = [[UIView alloc] init];
    self.cardView.translatesAutoresizingMaskIntoConstraints = NO;
    self.cardView.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] applyEffectToView:self.cardView];
    self.cardView.layer.cornerRadius = 16;
    self.cardView.layer.masksToBounds = YES;
    [self.view addSubview:self.cardView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.text = @"正在安装";
    [self.cardView addSubview:self.titleLabel];

    self.percentLabel = [[UILabel alloc] init];
    self.percentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.percentLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightHeavy];
    self.percentLabel.textAlignment = NSTextAlignmentCenter;
    // 使用启动器主题强调色（accentColor），与启动按钮/菜单选中态保持一致。
    // 用户在设置中切换主题色后，进度百分比会同步变色（FCL auto_tint 风格）。
    self.percentLabel.textColor = accentColor();
    self.percentLabel.text = @"0%";
    [self.cardView addSubview:self.percentLabel];

    self.indeterminateIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.indeterminateIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.indeterminateIndicator.hidesWhenStopped = YES;
    self.indeterminateIndicator.hidden = YES;
    [self.cardView addSubview:self.indeterminateIndicator];

    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.progress = 0.0;
    // 进度条填充色跟随主题强调色（accentColor），与百分比数字、启动按钮统一
    self.progressBar.progressTintColor = accentColor();
    [self.cardView addSubview:self.progressBar];

    self.stageLabel = [[UILabel alloc] init];
    self.stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.stageLabel.font = [UIFont systemFontOfSize:14];
    self.stageLabel.textAlignment = NSTextAlignmentCenter;
    self.stageLabel.textColor = [UIColor secondaryLabelColor];
    self.stageLabel.numberOfLines = 0;
    self.stageLabel.text = @"准备中...";
    [self.cardView addSubview:self.stageLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.cardView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.cardView.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor],
        [self.cardView.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor],

        [self.titleLabel.topAnchor constraintEqualToAnchor:self.cardView.topAnchor constant:24],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        [self.percentLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20],
        [self.percentLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.percentLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],

        [self.indeterminateIndicator.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:20],
        [self.indeterminateIndicator.centerXAnchor constraintEqualToAnchor:self.cardView.centerXAnchor],

        [self.progressBar.topAnchor constraintEqualToAnchor:self.percentLabel.bottomAnchor constant:16],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],
        [self.progressBar.heightAnchor constraintEqualToConstant:8],

        [self.stageLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:12],
        [self.stageLabel.leadingAnchor constraintEqualToAnchor:self.cardView.leadingAnchor constant:16],
        [self.stageLabel.trailingAnchor constraintEqualToAnchor:self.cardView.trailingAnchor constant:-16],
        [self.stageLabel.bottomAnchor constraintEqualToAnchor:self.cardView.bottomAnchor constant:-24]
    ]];
}

- (void)setTitleText:(NSString *)titleText {
    _titleText = [titleText copy];
    self.titleLabel.text = titleText ?: @"正在安装";
    self.title = titleText ?: @"正在安装";
}

- (void)setStageMessage:(NSString *)stageMessage {
    _stageMessage = [stageMessage copy];
    [self updateUI];
}

- (void)setProgress:(double)progress {
    _progress = progress;
    [self updateUI];
}

- (void)updateUI {
    if (self.progress < 0) {
        // 不确定模式：隐藏进度条与百分比，只显示转圈
        self.progressBar.hidden = YES;
        self.percentLabel.hidden = YES;
        self.indeterminateIndicator.hidden = NO;
        [self.indeterminateIndicator startAnimating];
    } else {
        self.progressBar.hidden = NO;
        self.percentLabel.hidden = NO;
        self.indeterminateIndicator.hidden = YES;
        [self.indeterminateIndicator stopAnimating];
        double clamped = MAX(0.0, MIN(1.0, self.progress));
        NSInteger percent = (NSInteger)(clamped * 100);
        self.percentLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.progressBar setProgress:(float)clamped animated:YES];
    }
    self.stageLabel.text = self.stageMessage ?: @"";
}

- (void)cancelTapped {
    if (self.cancelHandler) {
        self.cancelHandler();
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}

@end

#pragma mark - DownloadViewController

@interface DownloadViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, ModVersionViewControllerDelegate, ShaderVersionViewControllerDelegate, AssetVersionViewControllerDelegate>

@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UISegmentedControl *versionFilterSegment;
// versionFilterSegment 高度约束：版本 tab 显示（约 32pt），其他 tab 设为 0，
// 避免 hidden=YES 时仍占空间导致 tabSegment 与 searchBar 之间出现"大白条"。
@property (nonatomic, strong) NSLayoutConstraint *versionFilterHeightConstraint;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIButton *filterButton;
@property (nonatomic, strong) UIButton *importModpackButton;  // 整合包 tab 专用导入按钮（参照 FCL）
@property (nonatomic, strong) NSLayoutConstraint *importModpackButtonWidthConstraint;
@property (nonatomic, strong) UICollectionView *versionCollectionView;
@property (nonatomic, strong) UITableView *modTableView;
@property (nonatomic, strong) UITableView *shaderTableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, strong) NSArray *filteredVersions;
@property (nonatomic, strong) NSMutableArray *modList;
@property (nonatomic, strong) NSMutableArray *shaderList;

// 版本 tab 搜索关键词（按版本号前缀过滤，例如输入 "1.2" 匹配 1.20.x / 1.2.x）
@property (nonatomic, strong) NSString *versionSearchQuery;

@property (nonatomic, assign) NSInteger currentModOffset;
@property (nonatomic, assign) NSInteger currentShaderOffset;
@property (nonatomic, assign) BOOL isLoadingMore;
@property (nonatomic, assign) BOOL hasMoreMods;
@property (nonatomic, assign) BOOL hasMoreShaders;
@property (nonatomic, strong) NSString *currentSearchQuery;
@property (nonatomic, strong) NSString *currentGameVersion;
@property (nonatomic, strong) NSString *currentModLoader;
@property (nonatomic, strong) NSString *currentSortField;

@property (nonatomic, strong) MinecraftResourceDownloadTask *downloadTask;
@property (nonatomic, strong) DownloadProgressViewController *progressVC;
@property (nonatomic, strong) InlineMessageView *downloadingAlert;

@property (nonatomic, assign) BOOL isObservingProgress;

// 整合包相关属性
@property (nonatomic, strong) UITableView *modpackTableView;
@property (nonatomic, strong) NSMutableArray *modpackList;
@property (nonatomic, assign) NSInteger currentModpackOffset;
@property (nonatomic, assign) BOOL hasMoreModpacks;
@property (nonatomic, assign) BOOL isLoadingModpacks;
@property (nonatomic, strong) NSString *modpackSearchQuery;

// 资源包相关属性
@property (nonatomic, strong) UITableView *resourcepackTableView;
@property (nonatomic, strong) NSMutableArray *resourcepackList;
@property (nonatomic, assign) NSInteger currentResourcepackOffset;
@property (nonatomic, assign) BOOL hasMoreResourcepacks;
@property (nonatomic, assign) BOOL isLoadingResourcepacks;
@property (nonatomic, strong) NSString *resourcepackSearchQuery;

// 数据包相关属性
@property (nonatomic, strong) UITableView *datapackTableView;
@property (nonatomic, strong) NSMutableArray *datapackList;
@property (nonatomic, assign) NSInteger currentDatapackOffset;
@property (nonatomic, assign) BOOL hasMoreDatapacks;
@property (nonatomic, assign) BOOL isLoadingDatapacks;
@property (nonatomic, strong) NSString *datapackSearchQuery;

// 世界相关属性（仿 FCL 安卓新增世界下载分类）
@property (nonatomic, strong) UITableView *worldTableView;
@property (nonatomic, strong) NSMutableArray *worldList;
@property (nonatomic, assign) NSInteger currentWorldOffset;
@property (nonatomic, assign) BOOL hasMoreWorlds;
@property (nonatomic, assign) BOOL isLoadingWorlds;
@property (nonatomic, strong) NSString *worldSearchQuery;

// 源切换 UI（仿 FCL 安卓风格的圆角胶囊切换器：Modrinth 绿 / CurseForge 橙）
@property (nonatomic, strong) UIView *sourceSwitchContainer;
@property (nonatomic, strong) UIView *sourceSwitchTrack;        // 圆角胶囊背景轨道
@property (nonatomic, strong) UIView *sourceSwitchSlider;       // 选中项的彩色滑块
@property (nonatomic, strong) UIButton *modrinthSourceButton;
@property (nonatomic, strong) UIButton *curseforgeSourceButton;
@property (nonatomic, strong) NSLayoutConstraint *sourceSwitchHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *sliderLeftPosConstraint;   // 滑块贴左（Modrinth）
@property (nonatomic, strong) NSLayoutConstraint *sliderRightPosConstraint;  // 滑块贴右（CurseForge）

// 当前待下载资源类型（mod/resourcepack/datapack/world/modpack），用于版本选择回调中决定下载目录
@property (nonatomic, copy) NSString *pendingDownloadType;
// 在线选择版本时临时持有的资源包/数据包/世界对象（AssetVersionViewController 回调使用）
@property (nonatomic, strong, nullable) ResourcePackItem *pendingResourcePackItem;
@property (nonatomic, strong, nullable) DataPackItem *pendingDataPackItem;
@property (nonatomic, strong, nullable) WorldItem *pendingWorldItem;
// 整合包版本选择回调时临时持有的整合包字典（ModVersionViewController 回调使用，与 Mod 共用 VC 但下载流程不同）
@property (nonatomic, strong, nullable) NSDictionary *pendingModpackDict;

// 模组加载器安装进度 VC（FCL 风格进度展示，替代转圈 alert）
@property (nonatomic, strong) InstallerProgressViewController *installerProgressVC;

// 原版前置安装（FCL 风格：安装模组加载器前先装好对应原版）
@property (nonatomic, strong) MinecraftResourceDownloadTask *vanillaPreinstallTask;
@property (nonatomic, strong) InstallerProgressViewController *vanillaPreinstallProgressVC;
@property (nonatomic, assign) BOOL isObservingVanillaPreinstall;
@property (nonatomic, copy, nullable) void (^vanillaPreinstallCompletion)(BOOL success);

@end

@implementation DownloadViewController

- (void)dealloc {
    if (self.isObservingProgress) {
        [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        self.isObservingProgress = NO;
    }
    if (self.downloadTask) {
        [self.downloadTask.progress cancel];
        self.downloadTask = nil;
    }
    // 清理原版前置安装的 KVO 观察者，避免 VC 释放后 KVO 回调向已释放对象发送消息导致崩溃
    if (self.isObservingVanillaPreinstall) {
        [self.vanillaPreinstallTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        self.isObservingVanillaPreinstall = NO;
    }
    if (self.vanillaPreinstallTask) {
        [self.vanillaPreinstallTask.progress cancel];
        self.vanillaPreinstallTask = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];

    // 导航栏左侧：服务器入口（Modrinth Server Projects + CurseForge server packs）
    UIBarButtonItem *serverItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"network"]
                                                                      style:UIBarButtonItemStylePlain
                                                                     target:self
                                                                     action:@selector(openServerList)];
    serverItem.tintColor = [UIColor labelColor];
    self.navigationItem.leftBarButtonItem = serverItem;

    // 导航栏右侧：CurseForge API Key 配置入口，避免用户在 Modrinth 模式下找不到配置路径
    UIBarButtonItem *apiKeyItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"key.fill"]
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:self
                                                                    action:@selector(openCurseForgeAPIKeySettings)];
    apiKeyItem.tintColor = [UIColor labelColor];
    self.navigationItem.rightBarButtonItem = apiKeyItem;

    self.modList = [NSMutableArray array];
    self.shaderList = [NSMutableArray array];
    self.modpackList = [NSMutableArray array]; // 新增
    self.resourcepackList = [NSMutableArray array];
    self.datapackList = [NSMutableArray array];
    self.worldList = [NSMutableArray array];
    self.currentModOffset = 0;
    self.currentShaderOffset = 0;
    self.currentModpackOffset = 0;
    self.currentResourcepackOffset = 0;
    self.currentDatapackOffset = 0;
    self.currentWorldOffset = 0;
    self.hasMoreMods = YES;
    self.hasMoreShaders = YES;
    self.hasMoreModpacks = YES;
    self.hasMoreResourcepacks = YES;
    self.hasMoreDatapacks = YES;
    self.hasMoreWorlds = YES;
    self.currentSortField = @"follows";
    self.isObservingProgress = NO;

    [self setupUI];
    [self switchToTab:0];
    [self loadVersionList];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupSourceSwitch];
    [self setupVersionCollectionView];
    [self setupModTableView];
    [self setupShaderTableView];
    [self setupModpackTableView]; // 新增
    [self setupResourcepackTableView];
    [self setupDatapackTableView];
    [self setupWorldTableView];
    [self setupLoadingIndicator];
    [self setupEmptyLabel];
}

- (void)setupTabSegment {
    // 精简标签文字，避免在窄屏上拥挤截断
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"版本", @"模组", @"光影", @"资源包", @"数据包", @"整合包", @"世界"]];
    self.tabSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabSegment.selectedSegmentIndex = 0;
    [self.tabSegment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.tabSegment];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabSegment.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.tabSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.tabSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];
}

- (void)setupVersionFilterSegment {
    self.versionFilterSegment = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"正式版", @"测试版", @"远古版"]];
    self.versionFilterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionFilterSegment.selectedSegmentIndex = 0;
    [self.versionFilterSegment addTarget:self action:@selector(versionFilterChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.versionFilterSegment];

    // 高度约束：版本 tab 时设为 32（系统默认 UISegmentedControl 高度），其他 tab 设为 0
    // 避免 hidden=YES 仍占空间导致 tabSegment 与 searchBar 之间出现"大白条"
    self.versionFilterHeightConstraint = [self.versionFilterSegment.heightAnchor constraintEqualToConstant:32];

    [NSLayoutConstraint activateConstraints:@[
        [self.versionFilterSegment.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        [self.versionFilterSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionFilterSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        self.versionFilterHeightConstraint
    ]];
}

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = @"搜索版本...";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // 搜索框对所有 tab 都显示（版本 tab 用于按版本号前缀过滤）
    self.searchBar.hidden = NO;
    [self.view addSubview:self.searchBar];

    self.filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.filterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    [self.filterButton addTarget:self action:@selector(showFilterOptions) forControlEvents:UIControlEventTouchUpInside];
    self.filterButton.hidden = YES;
    [self.view addSubview:self.filterButton];

    // 整合包 tab 专用"导入本地整合包"按钮（参照 FCL 安卓在整合包列表上方提供显眼导入入口）
    self.importModpackButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.importModpackButton.translatesAutoresizingMaskIntoConstraints = NO;
    // square.and.arrow.down.on.square 是 iOS 14+ 符号，加 fallback 避免显示成方块
    UIImage *importIcon = [UIImage systemImageNamed:@"square.and.arrow.down.on.square"]
                          ?: [UIImage systemImageNamed:@"square.and.arrow.down"]
                          ?: [UIImage systemImageNamed:@"tray.and.arrow.down"];
    [self.importModpackButton setImage:importIcon forState:UIControlStateNormal];
    [self.importModpackButton setTitle:@"导入" forState:UIControlStateNormal];
    self.importModpackButton.tintColor = [UIColor whiteColor];
    self.importModpackButton.backgroundColor = [UIColor systemPurpleColor];
    self.importModpackButton.layer.cornerRadius = 10;
    self.importModpackButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.importModpackButton.contentEdgeInsets = UIEdgeInsetsMake(0, 10, 0, 10);
    self.importModpackButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.importModpackButton.hidden = YES;
    [self.importModpackButton addTarget:self action:@selector(openImportModpackView) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.importModpackButton];

    [NSLayoutConstraint activateConstraints:@[
        // 搜索框放在版本筛选框下方，避免与 versionFilterSegment 重合
        [self.searchBar.topAnchor constraintEqualToAnchor:self.versionFilterSegment.bottomAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.importModpackButton.leadingAnchor constant:-8],

        [self.importModpackButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.importModpackButton.trailingAnchor constraintEqualToAnchor:self.filterButton.leadingAnchor constant:-4],
        [self.importModpackButton.heightAnchor constraintEqualToConstant:36],

        [self.filterButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.filterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.filterButton.widthAnchor constraintEqualToConstant:44],
        [self.filterButton.heightAnchor constraintEqualToConstant:44]
    ]];

    // 默认宽度 0（隐藏时不占空间），整合包 tab 切换时设为 80
    self.importModpackButtonWidthConstraint = [self.importModpackButton.widthAnchor constraintEqualToConstant:0];
    self.importModpackButtonWidthConstraint.active = YES;
}

- (void)setupVersionCollectionView {
    // 参照 FCL (item_remote_version.xml 单列列表) 与 ZL2 (LazyColumn VersionItemLayout)：
    // 改为单列横向列表行布局，每行一个全宽卡片，行高 64pt（cell 内部再留 4pt 上下边距，实际卡片 56pt）。
    // itemSize.width 在 viewDidLayoutSubviews 里按 collectionView 实际宽度动态更新，避免横竖屏切换错位。
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 0;  // 单列，无横向间距
    layout.minimumLineSpacing = 4;       // 行间小间距，卡片自带阴影做视觉分隔
    layout.itemSize = CGSizeMake(360, 64); // 默认宽度，viewDidLayoutSubviews 会覆盖
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);

    self.versionCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.versionCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionCollectionView.backgroundColor = [UIColor clearColor];
    self.versionCollectionView.dataSource = self;
    self.versionCollectionView.delegate = self;
    // 选中态反馈：点击单元格时短暂高亮（FCL/ZL2 都有按压视觉反馈）
    self.versionCollectionView.allowsSelection = YES;
    self.versionCollectionView.alwaysBounceVertical = YES;
    [self.versionCollectionView registerClass:[VersionCardCell class] forCellWithReuseIdentifier:@"VersionCard"];
    [self.view addSubview:self.versionCollectionView];

    [NSLayoutConstraint activateConstraints:@[
        // 版本列表放在搜索框下方，避免与搜索框重合
        [self.versionCollectionView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.versionCollectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.versionCollectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.versionCollectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

// 动态更新版本列表 itemSize 宽度，使其填满 collectionView 宽度（减去 sectionInset 左右各 16pt）。
// 横屏切换或分屏尺寸变化时由系统自动调用，无需手动注册通知。
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.versionCollectionView) return;
    UICollectionViewFlowLayout *layout = (UICollectionViewFlowLayout *)self.versionCollectionView.collectionViewLayout;
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]]) return;
    CGFloat horizInset = layout.sectionInset.left + layout.sectionInset.right;
    CGFloat availableWidth = MAX(0, self.versionCollectionView.bounds.size.width - horizInset);
    CGSize target = CGSizeMake(availableWidth, 64);
    if (!CGSizeEqualToSize(layout.itemSize, target)) {
        layout.itemSize = target;
        // invalidateLayout 触发重新排版，避免 cell 复用时宽度滞后
        [layout invalidateLayout];
    }
}

- (void)setupModTableView {
    self.modTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modTableView.backgroundColor = [UIColor clearColor];
    self.modTableView.dataSource = self;
    self.modTableView.delegate = self;
    self.modTableView.rowHeight = 112;
    self.modTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModCell"];
    self.modTableView.hidden = YES;
    [self.view addSubview:self.modTableView];
    
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModList) forControlEvents:UIControlEventValueChanged];
    self.modTableView.refreshControl = refreshControl;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.modTableView.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor constant:4],
        [self.modTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.modTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupShaderTableView {
    self.shaderTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.shaderTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.shaderTableView.backgroundColor = [UIColor clearColor];
    self.shaderTableView.dataSource = self;
    self.shaderTableView.delegate = self;
    self.shaderTableView.rowHeight = 112;
    self.shaderTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.shaderTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ShaderCell"];
    self.shaderTableView.hidden = YES;
    [self.view addSubview:self.shaderTableView];
    
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshShaderList) forControlEvents:UIControlEventValueChanged];
    self.shaderTableView.refreshControl = refreshControl;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.shaderTableView.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor constant:4],
        [self.shaderTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.shaderTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.shaderTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupModpackTableView {
    self.modpackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modpackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modpackTableView.backgroundColor = [UIColor clearColor];
    self.modpackTableView.dataSource = self;
    self.modpackTableView.delegate = self;
    self.modpackTableView.rowHeight = 112;
    self.modpackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modpackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModpackCell"];
    self.modpackTableView.hidden = YES;
    [self.view addSubview:self.modpackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModpackList) forControlEvents:UIControlEventValueChanged];
    self.modpackTableView.refreshControl = refreshControl;

    [NSLayoutConstraint activateConstraints:@[
        [self.modpackTableView.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor constant:4],
        [self.modpackTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.modpackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.modpackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupResourcepackTableView {
    self.resourcepackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.resourcepackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.resourcepackTableView.backgroundColor = [UIColor clearColor];
    self.resourcepackTableView.dataSource = self;
    self.resourcepackTableView.delegate = self;
    self.resourcepackTableView.rowHeight = 112;
    self.resourcepackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.resourcepackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ResourcepackCell"];
    self.resourcepackTableView.hidden = YES;
    [self.view addSubview:self.resourcepackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshResourcepackList) forControlEvents:UIControlEventValueChanged];
    self.resourcepackTableView.refreshControl = refreshControl;

    [NSLayoutConstraint activateConstraints:@[
        [self.resourcepackTableView.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor constant:4],
        [self.resourcepackTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.resourcepackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.resourcepackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupDatapackTableView {
    self.datapackTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.datapackTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.datapackTableView.backgroundColor = [UIColor clearColor];
    self.datapackTableView.dataSource = self;
    self.datapackTableView.delegate = self;
    self.datapackTableView.rowHeight = 112;
    self.datapackTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.datapackTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"DatapackCell"];
    self.datapackTableView.hidden = YES;
    [self.view addSubview:self.datapackTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshDatapackList) forControlEvents:UIControlEventValueChanged];
    self.datapackTableView.refreshControl = refreshControl;

    [NSLayoutConstraint activateConstraints:@[
        [self.datapackTableView.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor constant:4],
        [self.datapackTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.datapackTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.datapackTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupWorldTableView {
    self.worldTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.worldTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.worldTableView.backgroundColor = [UIColor clearColor];
    self.worldTableView.dataSource = self;
    self.worldTableView.delegate = self;
    self.worldTableView.rowHeight = 112;
    self.worldTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.worldTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"WorldCell"];
    self.worldTableView.hidden = YES;
    [self.view addSubview:self.worldTableView];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshWorldList) forControlEvents:UIControlEventValueChanged];
    self.worldTableView.refreshControl = refreshControl;

    [NSLayoutConstraint activateConstraints:@[
        [self.worldTableView.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor constant:4],
        [self.worldTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.worldTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.worldTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupSourceSwitch {
    // 仿 FCL 安卓风格：居中的圆角胶囊切换器，带彩色滑块与品牌色
    self.sourceSwitchContainer = [[UIView alloc] init];
    self.sourceSwitchContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchContainer.hidden = YES;
    [self.view addSubview:self.sourceSwitchContainer];

    // 圆角胶囊背景轨道
    self.sourceSwitchTrack = [[UIView alloc] init];
    self.sourceSwitchTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchTrack.backgroundColor = [UIColor tertiarySystemFillColor];
    self.sourceSwitchTrack.layer.cornerRadius = 16;
    self.sourceSwitchTrack.layer.masksToBounds = YES;
    [self.sourceSwitchContainer addSubview:self.sourceSwitchTrack];

    // 选中项滑块（初始为 Modrinth 绿）
    self.sourceSwitchSlider = [[UIView alloc] init];
    self.sourceSwitchSlider.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceSwitchSlider.backgroundColor = [UIColor systemGreenColor];
    self.sourceSwitchSlider.layer.cornerRadius = 14;
    // 阴影提升层次感
    self.sourceSwitchSlider.layer.shadowColor = [UIColor blackColor].CGColor;
    self.sourceSwitchSlider.layer.shadowOpacity = 0.15;
    self.sourceSwitchSlider.layer.shadowOffset = CGSizeMake(0, 1);
    self.sourceSwitchSlider.layer.shadowRadius = 3;
    [self.sourceSwitchTrack addSubview:self.sourceSwitchSlider];

    // Modrinth 按钮
    self.modrinthSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.modrinthSourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modrinthSourceButton setTitle:@"Modrinth" forState:UIControlStateNormal];
    self.modrinthSourceButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.modrinthSourceButton addTarget:self action:@selector(modrinthSourceButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceSwitchTrack addSubview:self.modrinthSourceButton];

    // CurseForge 按钮
    self.curseforgeSourceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.curseforgeSourceButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.curseforgeSourceButton setTitle:@"CurseForge" forState:UIControlStateNormal];
    self.curseforgeSourceButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.curseforgeSourceButton addTarget:self action:@selector(curseforgeSourceButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceSwitchTrack addSubview:self.curseforgeSourceButton];

    // 容器约束：居中、固定宽度、固定高度
    self.sliderLeftPosConstraint = [self.sourceSwitchSlider.leadingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.leadingAnchor constant:2];
    self.sliderRightPosConstraint = [self.sourceSwitchSlider.trailingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.trailingAnchor constant:-2];
    self.sliderRightPosConstraint.active = NO; // 初始 Modrinth 在左

    [NSLayoutConstraint activateConstraints:@[
        [self.sourceSwitchContainer.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:6],
        [self.sourceSwitchContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.sourceSwitchContainer.widthAnchor constraintEqualToConstant:220],
        [self.sourceSwitchContainer.heightAnchor constraintEqualToConstant:36],

        // 轨道铺满容器
        [self.sourceSwitchTrack.topAnchor constraintEqualToAnchor:self.sourceSwitchContainer.topAnchor],
        [self.sourceSwitchTrack.leadingAnchor constraintEqualToAnchor:self.sourceSwitchContainer.leadingAnchor],
        [self.sourceSwitchTrack.trailingAnchor constraintEqualToAnchor:self.sourceSwitchContainer.trailingAnchor],
        [self.sourceSwitchTrack.bottomAnchor constraintEqualToAnchor:self.sourceSwitchContainer.bottomAnchor],

        // 滑块高度/宽度（宽度 = 轨道一半 - 2pt 边距），位置由 left/right 约束二选一定位
        [self.sourceSwitchSlider.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor constant:2],
        [self.sourceSwitchSlider.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor constant:-2],
        [self.sourceSwitchSlider.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5 constant:-2],
        self.sliderLeftPosConstraint,

        // 两个按钮各占一半
        [self.modrinthSourceButton.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor],
        [self.modrinthSourceButton.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor],
        [self.modrinthSourceButton.leadingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.leadingAnchor],
        [self.modrinthSourceButton.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5],

        [self.curseforgeSourceButton.topAnchor constraintEqualToAnchor:self.sourceSwitchTrack.topAnchor],
        [self.curseforgeSourceButton.bottomAnchor constraintEqualToAnchor:self.sourceSwitchTrack.bottomAnchor],
        [self.curseforgeSourceButton.trailingAnchor constraintEqualToAnchor:self.sourceSwitchTrack.trailingAnchor],
        [self.curseforgeSourceButton.widthAnchor constraintEqualToAnchor:self.sourceSwitchTrack.widthAnchor multiplier:0.5]
    ]];

    // 动态高度约束（隐藏时为 0，显示时为 36）
    self.sourceSwitchHeightConstraint = [self.sourceSwitchContainer.heightAnchor constraintEqualToConstant:0];
    self.sourceSwitchHeightConstraint.active = YES;
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    self.loadingIndicator.color = [UIColor labelColor];
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

- (void)setupEmptyLabel {
    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyLabel.text = @"暂无内容";
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

#pragma mark - Tab Switching

- (void)tabChanged:(UISegmentedControl *)sender {
    [self switchToTab:sender.selectedSegmentIndex];
}

- (void)switchToTab:(NSInteger)index {
    // 列表切换使用淡入淡出，避免生硬的瞬间 hidden 切换
    [UIView transitionWithView:self.view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.versionFilterSegment.hidden = (index != 0);
        self.versionCollectionView.hidden = (index != 0);
        // 搜索框对所有 tab 都显示（版本 tab 用于按版本号前缀过滤本地+远程版本列表）
        self.searchBar.hidden = NO;
        // 过滤按钮仅在版本 tab 显示（用于调出版本类型筛选/排序选项）
        self.filterButton.hidden = (index != 0);
        self.modTableView.hidden = (index != 1);
        self.shaderTableView.hidden = (index != 2);
        self.resourcepackTableView.hidden = (index != 3);
        self.datapackTableView.hidden = (index != 4);
        self.modpackTableView.hidden = (index != 5);
        self.worldTableView.hidden = (index != 6);
    } completion:nil];

    // 源切换仅在非版本 tab 显示；世界 tab 强制 CurseForge，无需切换
    BOOL showSourceSwitch = (index != 0 && index != 6);
    self.sourceSwitchContainer.hidden = !showSourceSwitch;
    self.sourceSwitchHeightConstraint.constant = showSourceSwitch ? 36 : 0;

    // versionFilterSegment 高度同步切换：版本 tab 显示 32pt，其他 tab 设为 0 不占空间，
    // 避免 hidden=YES 仍占空间导致 tabSegment 与 searchBar 之间出现"大白条"
    self.versionFilterHeightConstraint.constant = (index == 0) ? 32 : 0;

    // 整合包 tab 显示"导入本地整合包"按钮（参照 FCL 安卓），其他 tab 隐藏且宽度归零不占空间
    BOOL showImportButton = (index == 5);
    self.importModpackButton.hidden = !showImportButton;
    self.importModpackButtonWidthConstraint.constant = showImportButton ? 80 : 0;

    [UIView animateWithDuration:0.2 animations:^{
        [self.view layoutIfNeeded];
    }];

    if (index == 0) {
        // 版本 tab：按版本号前缀过滤版本列表
        self.searchBar.placeholder = @"搜索版本...";
        // 版本 tab 不需要源切换
    } else if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        [self updateSourceSwitchButtonsForType:@"mod"];
        if (self.modList.count == 0) {
            [self loadModList];
        }
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        [self updateSourceSwitchButtonsForType:@"shader"];
        if (self.shaderList.count == 0) {
            [self loadShaderList];
        }
    } else if (index == 3) {
        self.searchBar.placeholder = @"搜索资源包...";
        [self updateSourceSwitchButtonsForType:@"resourcepack"];
        if (self.resourcepackList.count == 0) {
            [self loadResourcePackList];
        }
    } else if (index == 4) {
        self.searchBar.placeholder = @"搜索数据包...";
        [self updateSourceSwitchButtonsForType:@"datapack"];
        if (self.datapackList.count == 0) {
            [self loadDataPackList];
        }
    } else if (index == 5) {
        self.searchBar.placeholder = @"搜索整合包...";
        [self updateSourceSwitchButtonsForType:@"modpack"];
        if (self.modpackList.count == 0) {
            [self loadModpackList];
        }
    } else if (index == 6) {
        self.searchBar.placeholder = @"搜索世界...";
        [self updateSourceSwitchButtonsForType:@"world"];
        if (self.worldList.count == 0) {
            [self loadWorldList];
        }
    }
}

#pragma mark - Source Switch

- (void)updateSourceSwitchButtonsForType:(NSString *)type {
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    BOOL isModrinth = [currentSource isEqualToString:@"modrinth"];

    // 选中项文字白色，未选中项使用 labelColor
    [self.modrinthSourceButton setTitleColor:isModrinth ? [UIColor whiteColor] : [UIColor labelColor] forState:UIControlStateNormal];
    [self.curseforgeSourceButton setTitleColor:isModrinth ? [UIColor labelColor] : [UIColor whiteColor] forState:UIControlStateNormal];

    // 滑块位置：通过激活 left/right 约束二选一切换，配合颜色动画
    self.sliderLeftPosConstraint.active = isModrinth;
    self.sliderRightPosConstraint.active = !isModrinth;
    UIColor *sliderColor = isModrinth ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.sourceSwitchSlider.backgroundColor = sliderColor;
        [self.sourceSwitchTrack layoutIfNeeded];
    } completion:nil];

    self.modrinthSourceButton.tag = [self tagForType:type];
    self.curseforgeSourceButton.tag = [self tagForType:type];
}

- (NSInteger)tagForType:(NSString *)type {
    if ([type isEqualToString:@"mod"]) return 1;
    if ([type isEqualToString:@"shader"]) return 2;
    if ([type isEqualToString:@"resourcepack"]) return 3;
    if ([type isEqualToString:@"datapack"]) return 4;
    if ([type isEqualToString:@"modpack"]) return 5;
    if ([type isEqualToString:@"world"]) return 6;
    return 0;
}

- (NSString *)typeForTag:(NSInteger)tag {
    switch (tag) {
        case 1: return @"mod";
        case 2: return @"shader";
        case 3: return @"resourcepack";
        case 4: return @"datapack";
        case 5: return @"modpack";
        case 6: return @"world";
        default: return @"mod";
    }
}

- (NSString *)currentTabType {
    NSInteger index = self.tabSegment.selectedSegmentIndex;
    switch (index) {
        case 1: return @"mod";
        case 2: return @"shader";
        case 3: return @"resourcepack";
        case 4: return @"datapack";
        case 5: return @"modpack";
        case 6: return @"world";
        default: return @"mod";
    }
}

- (void)modrinthSourceButtonClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"modrinth"]) return;

    [PLPreferences setDownloadSource:@"modrinth" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

- (void)curseforgeSourceButtonClicked:(UIButton *)sender {
    NSString *type = [self typeForTag:sender.tag];
    NSString *currentSource = [PLPreferences currentDownloadSourceForType:type];
    if ([currentSource isEqualToString:@"curseforge"]) return;

    // API Key 未配置时在内容区显示提示（替代弹窗）
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:@"需要 CurseForge API Key"
                                                                    message:@"检测到未配置 CurseForge API Key，点击前往设置"
                                                                       type:InlineMessageTypeInfo];
        // 2 秒后自动跳转设置页
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            [self openCurseForgeAPIKeySettings];
        });
        return;
    }

    [PLPreferences setDownloadSource:@"curseforge" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

- (id)currentAPIForTabType:(NSString *)type {
    // Modrinth 不支持 project_type:world facet (其 project_type 仅 mod/modpack/shader/resourcepack/plugin)
    // 世界 tab 强制走 CurseForge (classID 17 = Worlds 真实存在)
    if ([type isEqualToString:@"world"]) {
        return [CurseForgeAPI sharedInstance];
    }
    NSString *source = [PLPreferences currentDownloadSourceForType:type];
    if ([source isEqualToString:@"curseforge"]) {
        return [CurseForgeAPI sharedInstance];
    }
    return [ModrinthAPI sharedInstance];
}

// 导航栏 API Key 入口：直接 push 配置页，不再走 alert 通知绕路
- (void)openCurseForgeAPIKeySettings {
    CurseForgeAPIKeyViewController *vc = [[CurseForgeAPIKeyViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

// 导航栏服务器入口：弹出 ServerListViewController（自带双源切换、搜索、详情导航）
- (void)openServerList {
    ServerListViewController *vc = [ServerListViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Data Loading

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL;
    
    if ([downloadSource isEqualToString:@"bmclapi"]) {
        versionManifestURL = @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json";
    } else {
        versionManifestURL = @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    }
    
    NSURL *url = [NSURL URLWithString:versionManifestURL];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    strongSelf.versionList = json[@"versions"];
                    [strongSelf applyVersionFilter];
                } else {
                    strongSelf.emptyLabel.text = @"加载版本列表失败";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else {
                strongSelf.emptyLabel.text = @"网络错误，无法加载版本";
                strongSelf.emptyLabel.hidden = NO;
            }
        });
    }];
    [task resume];
}

- (void)versionFilterChanged:(UISegmentedControl *)sender {
    [self applyVersionFilter];
}

- (void)applyVersionFilter {
    if (!self.versionList) return;
    
    NSInteger filterIndex = self.versionFilterSegment.selectedSegmentIndex;
    // 搜索关键词：忽略大小写与首尾空格，按版本号前缀匹配
    NSString *query = [self.versionSearchQuery stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *lowerQuery = query.lowercaseString;
    BOOL hasQuery = (lowerQuery.length > 0);
    
    NSMutableArray *filtered = [NSMutableArray array];
    
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        
        BOOL typeMatch = NO;
        if (filterIndex == 0) {
            typeMatch = YES;
        } else if (filterIndex == 1 && [type isEqualToString:@"release"]) {
            typeMatch = YES;
        } else if (filterIndex == 2 && [type isEqualToString:@"snapshot"]) {
            typeMatch = YES;
        } else if (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"])) {
            typeMatch = YES;
        }
        if (!typeMatch) continue;
        
        // 应用搜索关键词过滤（按 id 前缀匹配，例如 "1.2" 命中 "1.20.4"）
        if (hasQuery) {
            NSString *versionId = version[@"id"];
            if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) continue;
            if (![versionId.lowercaseString hasPrefix:lowerQuery]) continue;
        }
        
        [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
    
    self.emptyLabel.hidden = (self.filteredVersions.count > 0);
    if (self.filteredVersions.count == 0) {
        self.emptyLabel.text = hasQuery ? @"未匹配到版本" : @"暂无版本";
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

#pragma mark - Mod Search & Loading

- (void)refreshModList {
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self loadModList];
}

- (void)loadModList {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    if (self.currentModOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentModOffset);
    
    if (self.currentSearchQuery.length > 0) {
        filters[@"query"] = self.currentSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    if (self.currentModLoader.length > 0) {
        filters[@"loader"] = self.currentModLoader;
    }
    if (self.currentSortField.length > 0) {
        filters[@"sort"] = self.currentSortField;
    }
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"mod"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.modTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMore = NO;
            
            if (results) {
                if (strongSelf.currentModOffset == 0) {
                    [strongSelf.modList removeAllObjects];
                }
                [strongSelf.modList addObjectsFromArray:results];
                strongSelf.hasMoreMods = (results.count >= 30);
                strongSelf.currentModOffset += results.count;
                
                [strongSelf.modTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.modList.count > 0);
                if (strongSelf.modList.count == 0) {
                    strongSelf.emptyLabel.text = @"暂无模组";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchMods:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

#pragma mark - Shader Search & Loading

- (void)refreshShaderList {
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self loadShaderList];
}

- (void)loadShaderList {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    if (self.currentShaderOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentShaderOffset);
    filters[@"projectType"] = @"shader";

    if (self.currentSearchQuery.length > 0) {
        filters[@"query"] = self.currentSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"shader"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.shaderTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMore = NO;
            
            if (results) {
                if (strongSelf.currentShaderOffset == 0) {
                    [strongSelf.shaderList removeAllObjects];
                }
                [strongSelf.shaderList addObjectsFromArray:results];
                strongSelf.hasMoreShaders = (results.count >= 30);
                strongSelf.currentShaderOffset += results.count;
                
                [strongSelf.shaderTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.shaderList.count > 0);
                if (strongSelf.shaderList.count == 0) {
                    strongSelf.emptyLabel.text = @"暂无光影";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchShaders:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self.shaderTableView reloadData];
    [self loadShaderList];
}

#pragma mark - Modpack Search & Loading

- (void)refreshModpackList {
    self.currentModpackOffset = 0;
    self.hasMoreModpacks = YES;
    [self.modpackList removeAllObjects];
    [self loadModpackList];
}

- (void)loadModpackList {
    if (self.isLoadingModpacks) return;
    self.isLoadingModpacks = YES;
    
    if (self.currentModpackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"isModpack"] = @YES;
    filters[@"projectType"] = @"modpack";
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentModpackOffset);
    if (self.modpackSearchQuery.length > 0) {
        filters[@"query"] = self.modpackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"modpack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.modpackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingModpacks = NO;
            
            if (results) {
                if (strongSelf.currentModpackOffset == 0) {
                    [strongSelf.modpackList removeAllObjects];
                }
                [strongSelf.modpackList addObjectsFromArray:results];
                strongSelf.hasMoreModpacks = (results.count >= 30);
                strongSelf.currentModpackOffset += results.count;
                
                [strongSelf.modpackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.modpackList.count > 0);
                if (strongSelf.modpackList.count == 0) {
                    strongSelf.emptyLabel.text = @"暂无整合包";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchModpacks:(NSString *)query {
    self.modpackSearchQuery = query;
    self.currentModpackOffset = 0;
    self.hasMoreModpacks = YES;
    [self.modpackList removeAllObjects];
    [self.modpackTableView reloadData];
    [self loadModpackList];
}

#pragma mark - Resourcepack Search & Loading

- (void)refreshResourcepackList {
    self.currentResourcepackOffset = 0;
    self.hasMoreResourcepacks = YES;
    [self.resourcepackList removeAllObjects];
    [self loadResourcePackList];
}

- (void)loadResourcePackList {
    if (self.isLoadingResourcepacks) return;
    self.isLoadingResourcepacks = YES;

    if (self.currentResourcepackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentResourcepackOffset);
    filters[@"projectType"] = @"resourcepack";

    if (self.resourcepackSearchQuery.length > 0) {
        filters[@"query"] = self.resourcepackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"resourcepack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.resourcepackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingResourcepacks = NO;

            if (results) {
                if (strongSelf.currentResourcepackOffset == 0) {
                    [strongSelf.resourcepackList removeAllObjects];
                }
                [strongSelf.resourcepackList addObjectsFromArray:results];
                strongSelf.hasMoreResourcepacks = (results.count >= 30);
                strongSelf.currentResourcepackOffset += results.count;

                [strongSelf.resourcepackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.resourcepackList.count > 0);
                if (strongSelf.resourcepackList.count == 0) {
                    strongSelf.emptyLabel.text = @"暂无资源包";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchResourcepacks:(NSString *)query {
    self.resourcepackSearchQuery = query;
    self.currentResourcepackOffset = 0;
    self.hasMoreResourcepacks = YES;
    [self.resourcepackList removeAllObjects];
    [self.resourcepackTableView reloadData];
    [self loadResourcePackList];
}

#pragma mark - Datapack Search & Loading

- (void)refreshDatapackList {
    self.currentDatapackOffset = 0;
    self.hasMoreDatapacks = YES;
    [self.datapackList removeAllObjects];
    [self loadDataPackList];
}

- (void)loadDataPackList {
    if (self.isLoadingDatapacks) return;
    self.isLoadingDatapacks = YES;

    if (self.currentDatapackOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentDatapackOffset);
    filters[@"projectType"] = @"datapack";

    if (self.datapackSearchQuery.length > 0) {
        filters[@"query"] = self.datapackSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"datapack"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.datapackTableView.refreshControl endRefreshing];
            strongSelf.isLoadingDatapacks = NO;

            if (results) {
                if (strongSelf.currentDatapackOffset == 0) {
                    [strongSelf.datapackList removeAllObjects];
                }
                [strongSelf.datapackList addObjectsFromArray:results];
                strongSelf.hasMoreDatapacks = (results.count >= 30);
                strongSelf.currentDatapackOffset += results.count;

                [strongSelf.datapackTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.datapackList.count > 0);
                if (strongSelf.datapackList.count == 0) {
                    strongSelf.emptyLabel.text = @"暂无数据包";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchDatapacks:(NSString *)query {
    self.datapackSearchQuery = query;
    self.currentDatapackOffset = 0;
    self.hasMoreDatapacks = YES;
    [self.datapackList removeAllObjects];
    [self.datapackTableView reloadData];
    [self loadDataPackList];
}

#pragma mark - World 加载

- (void)refreshWorldList {
    self.currentWorldOffset = 0;
    self.hasMoreWorlds = YES;
    [self.worldList removeAllObjects];
    [self loadWorldList];
}

- (void)loadWorldList {
    if (self.isLoadingWorlds) return;
    self.isLoadingWorlds = YES;

    if (self.currentWorldOffset == 0) {
        [self.loadingIndicator startAnimating];
    }

    // 世界 tab 强制 CurseForge，但需 API Key（与实际请求一致的三层 fallback 判断）；缺失时给出明确入口提示
    if (![CurseForgeAPI isAPIKeyConfigured]) {
        [self.loadingIndicator stopAnimating];
        [self.worldTableView.refreshControl endRefreshing];
        self.isLoadingWorlds = NO;
        [self.worldList removeAllObjects];
        [self.worldTableView reloadData];
        self.emptyLabel.text = @"世界列表需要 CurseForge API Key\n点击右上角筛选按钮配置";
        self.emptyLabel.hidden = NO;
        return;
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentWorldOffset);
    filters[@"projectType"] = @"world";

    if (self.worldSearchQuery.length > 0) {
        filters[@"query"] = self.worldSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }

    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"world"];
    [api searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.worldTableView.refreshControl endRefreshing];
            strongSelf.isLoadingWorlds = NO;

            if (results) {
                if (strongSelf.currentWorldOffset == 0) {
                    [strongSelf.worldList removeAllObjects];
                }
                [strongSelf.worldList addObjectsFromArray:results];
                strongSelf.hasMoreWorlds = (results.count >= 30);
                strongSelf.currentWorldOffset += results.count;

                [strongSelf.worldTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.worldList.count > 0);
                if (strongSelf.worldList.count == 0) {
                    strongSelf.emptyLabel.text = @"暂无世界";
                    strongSelf.emptyLabel.hidden = NO;
                }
            } else if (error) {
                [strongSelf showError:error.localizedDescription];
            }
        });
    }];
}

- (void)searchWorlds:(NSString *)query {
    self.worldSearchQuery = query;
    self.currentWorldOffset = 0;
    self.hasMoreWorlds = YES;
    [self.worldList removeAllObjects];
    [self.worldTableView reloadData];
    [self loadWorldList];
}

#pragma mark - Filter Options

- (void)showFilterOptions {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选项"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (tabIndex == 1 || tabIndex == 2 || tabIndex == 3 || tabIndex == 4) {
        [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"排序方式"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showSortOptions];
        }]];

        if (tabIndex == 1) {
            [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * _Nonnull action) {
                [self showModLoaderPicker];
            }]];
        }

        [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self resetFilters];
        }]];
    } else if (tabIndex == 5) {
        [alert addAction:[UIAlertAction actionWithTitle:@"导入本地整合包"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self openImportModpackView];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = nil;
            [self refreshModpackList];
        }]];
    } else if (tabIndex == 6) {
        // 世界 tab: 强制 CurseForge，提供 API Key 入口与版本筛选
        [alert addAction:[UIAlertAction actionWithTitle:@"设置 CurseForge API Key"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self openCurseForgeAPIKeySettings];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showGameVersionPicker];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = nil;
            [self refreshWorldList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showGameVersionPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择游戏版本"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *versions = @[@"全部版本", @"1.21", @"1.20.4", @"1.20.1", @"1.19.4", @"1.19.2", @"1.18.2", @"1.16.5", @"1.12.2", @"1.8.9"];
    
    for (NSString *version in versions) {
        [alert addAction:[UIAlertAction actionWithTitle:version
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            if ([version isEqualToString:@"全部版本"]) {
                self.currentGameVersion = nil;
            } else {
                self.currentGameVersion = version;
            }
            [self reloadCurrentList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSortOptions {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"排序方式"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSDictionary *sortOptions = @{
        @"关注度": @"follows",
        @"下载数": @"downloads",
        @"最近更新": @"updated",
        @"最新发布": @"newest",
        @"相关性": @"relevance"
    };
    
    for (NSString *title in sortOptions) {
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentSortField = sortOptions[title];
            [self reloadCurrentList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showModLoaderPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"模组加载器"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *loaderNames = @[@"全部", @"Fabric", @"Forge", @"Quilt", @"NeoForge"];
    NSArray *loaderValues = @[[NSNull null], @"fabric", @"forge", @"quilt", @"neoforge"];
    
    for (NSInteger i = 0; i < loaderNames.count; i++) {
        NSString *name = loaderNames[i];
        id value = loaderValues[i];
        
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.currentModLoader = (value == [NSNull null]) ? nil : value;
            [self reloadCurrentList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetFilters {
    self.currentGameVersion = nil;
    self.currentModLoader = nil;
    self.currentSortField = @"follows";
    self.currentSearchQuery = nil;
    self.resourcepackSearchQuery = nil;
    self.datapackSearchQuery = nil;
    self.searchBar.text = nil;
    [self reloadCurrentList];
}

- (void)reloadCurrentList {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    // 切换 API 源时对当前列表做淡出→加载→淡入，避免瞬间清空的生硬感
    UITableView *targetTable = nil;
    if (tabIndex == 1) {
        targetTable = self.modTableView;
        self.currentModOffset = 0;
        [self.modList removeAllObjects];
    } else if (tabIndex == 2) {
        targetTable = self.shaderTableView;
        self.currentShaderOffset = 0;
        [self.shaderList removeAllObjects];
    } else if (tabIndex == 3) {
        targetTable = self.resourcepackTableView;
        self.currentResourcepackOffset = 0;
        [self.resourcepackList removeAllObjects];
    } else if (tabIndex == 4) {
        targetTable = self.datapackTableView;
        self.currentDatapackOffset = 0;
        [self.datapackList removeAllObjects];
    } else if (tabIndex == 5) {
        targetTable = self.modpackTableView;
        self.currentModpackOffset = 0;
        [self.modpackList removeAllObjects];
    } else if (tabIndex == 6) {
        targetTable = self.worldTableView;
        self.currentWorldOffset = 0;
        [self.worldList removeAllObjects];
    }

    [UIView animateWithDuration:0.15 animations:^{
        targetTable.alpha = 0;
    } completion:^(BOOL finished) {
        switch (tabIndex) {
            case 1: [self loadModList]; break;
            case 2: [self loadShaderList]; break;
            case 3: [self loadResourcePackList]; break;
            case 4: [self loadDataPackList]; break;
            case 5: [self loadModpackList]; break;
            case 6: [self loadWorldList]; break;
        }
        [UIView animateWithDuration:0.2 animations:^{
            targetTable.alpha = 1;
        }];
    }];
}

- (void)showError:(NSString *)message {
    // 在内容区显示错误，替代弹窗
    [InlineMessageView showInViewController:self
                                       title:@"错误"
                                    message:message
                                       type:InlineMessageTypeError];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];

    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 0) {
        // 版本 tab：搜索过滤已在 textDidChange 实时执行，此处仅收起键盘
        // 不再重复调用 applyVersionFilter
    } else if (tabIndex == 1) {
        [self searchMods:searchBar.text];
    } else if (tabIndex == 2) {
        [self searchShaders:searchBar.text];
    } else if (tabIndex == 3) {
        [self searchResourcepacks:searchBar.text];
    } else if (tabIndex == 4) {
        [self searchDatapacks:searchBar.text];
    } else if (tabIndex == 5) {
        [self searchModpacks:searchBar.text];
    } else if (tabIndex == 6) {
        [self searchWorlds:searchBar.text];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = nil;
    self.currentSearchQuery = nil;
    self.modpackSearchQuery = nil;
    self.resourcepackSearchQuery = nil;
    self.datapackSearchQuery = nil;
    self.worldSearchQuery = nil;
    self.versionSearchQuery = nil;
    [searchBar resignFirstResponder];
    [self reloadCurrentList];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 0) {
        // 版本 tab：实时按版本号前缀过滤（无需点击搜索按钮）
        self.versionSearchQuery = searchText;
        [self applyVersionFilter];
    }
}

#pragma mark - UICollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];

    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    NSString *releaseTime = version[@"releaseTime"];
    NSString *versionType = version[@"type"];

    NSString *formattedDate = [self formatDate:releaseTime];
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];

    // FCL 风格：标记已安装的版本（遍历 PLProfiles，匹配 lastVersionId）
    [cell setInstalled:[self isVersionInstalled:versionId]];

    return cell;
}

/// 检查指定 versionId 是否已安装在本地（任一 profile 的 lastVersionId 匹配即视为已安装）
- (BOOL)isVersionInstalled:(NSString *)versionId {
    if (!versionId.length) return NO;
    NSDictionary *profiles = PLProfiles.current.profiles;
    for (NSString *name in profiles.allKeys) {
        NSDictionary *profile = profiles[name];
        NSString *lastVersionId = profile[@"lastVersionId"];
        if ([lastVersionId isKindOfClass:[NSString class]] && [lastVersionId isEqualToString:versionId]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)formatDate:(NSString *)dateString {
    if (dateString.length >= 10) {
        return [dateString substringToIndex:10];
    }
    return dateString;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    [self showLoaderSelectionForVersion:version];
}

#pragma mark - Loader Selection (push 到中间内容区)

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    ModLoaderInstallViewController *loaderVC = [[ModLoaderInstallViewController alloc] init];
    loaderVC.gameVersion = version[@"id"];

    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 先 pop 加载器选择页，再启动安装流程（与 FCL 安卓在中间内容区切换一致）
        [strongSelf.navigationController popViewControllerAnimated:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf proceedWithVersion:version loaderType:loaderType installFabricAPI:installFabricAPI installOptiFine:installOptiFine loaderVersion:loaderVersion];
        });
    };

    loaderVC.cancelled = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
        }
    };

    // 已在 DownloadVC 的导航栈中，直接 push，不再用 FormSheet 弹窗
    [self.navigationController pushViewController:loaderVC animated:YES];
}

#pragma mark - Installation

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    NSString *versionId = version[@"id"];

    if ([loaderType isEqualToString:@"vanilla"]) {
        [self downloadVanillaVersion:version];
        return;
    }

    // 参照 FCL：安装模组加载器前，先完整安装对应的原版（client.jar + libraries + assets）。
    // Fabric/Quilt/OptiFine 的版本 JSON 含 "inheritsFrom" 字段，启动时 Java 端
    // Tools.getVersionInfo() 会读取 versions/{inheritsFrom}/{inheritsFrom}.json 合并。
    // 若用户尚未安装原版，启动会因 FileNotFoundException 崩溃；仅下载 JSON 不够，
    // 还需下载 client.jar/资源/库，否则首次启动仍要现下、体验割裂。
    // Forge/NeoForge 直装器内部已有 ensureParentVersionExists 逻辑（仅 JSON），此处补全完整原版。
    __weak typeof(self) weakSelf = self;
    [self ensureVanillaInstalled:version completion:^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!success) {
            [strongSelf showError:[NSString stringWithFormat:@"无法安装原版 %@，请检查网络后重试", versionId]];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([loaderType isEqualToString:@"fabric"]) {
                [strongSelf installFabric:versionId loaderVersion:loaderVersion installAPI:installFabricAPI];
            } else if ([loaderType isEqualToString:@"forge"]) {
                [strongSelf installForge:versionId installOptiFine:installOptiFine loaderVersion:loaderVersion];
            } else if ([loaderType isEqualToString:@"neoforge"]) {
                [strongSelf installNeoForge:versionId loaderVersion:loaderVersion];
            } else if ([loaderType isEqualToString:@"quilt"]) {
                [strongSelf installQuilt:versionId loaderVersion:loaderVersion];
            } else if ([loaderType isEqualToString:@"optifine"]) {
                [strongSelf installOptiFineAsPatch:versionId loaderVersion:loaderVersion];
            } else {
                [strongSelf showError:[NSString stringWithFormat:@"%@ 安装器暂未实现", loaderType]];
            }
        });
    }];
}

/// 参照 FCL：确保原版版本的 version JSON 已存在。
/// 若 versions/{versionId}/{versionId}.json 不存在，从 Mojang/BMCLAPI 版本清单下载。
/// 仅下载 version JSON（不下载 client.jar/assets/libraries，这些在游戏首次启动时由 Java 端自动下载）。
/// Forge/NeoForge 直装器内部也有相同逻辑（ensureParentVersionExists），但 Fabric/Quilt/OptiFine 没有，
/// 因此在 proceedWithVersion 中统一前置调用。
- (void)ensureVanillaVersionJSONExists:(NSString *)versionId completion:(void (^)(BOOL success))completion {
    NSString *pojavHome = @(getenv("POJAV_HOME"));
    NSString *versionDir = [pojavHome stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.json", versionId]];

    // 1. 版本 JSON 已存在，无需下载
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        if (completion) completion(YES);
        return;
    }

    NSLog(@"[DownloadVC] Vanilla version JSON missing, downloading: %@", versionId);

    // 2. 在后台线程拉取 Mojang 版本清单并下载 version JSON
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
        BOOL useBMCLAPI = [downloadSource isEqualToString:@"bmclapi"];
        NSString *manifestURL = useBMCLAPI
            ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
            : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";

        NSURL *url = [NSURL URLWithString:manifestURL];
        if (!url) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSMutableURLRequest *manifestRequest = [NSMutableURLRequest requestWithURL:url];
        manifestRequest.timeoutInterval = 30.0;
        manifestRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [manifestRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        NSData *manifestData = [NSURLConnection sendSynchronousRequest:manifestRequest returningResponse:nil error:nil];
        if (!manifestData) {
            NSLog(@"[DownloadVC] Failed to download version manifest");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
        NSArray *versions = [manifest isKindOfClass:[NSDictionary class]] ? manifest[@"versions"] : nil;
        if (![versions isKindOfClass:[NSArray class]]) {
            NSLog(@"[DownloadVC] Invalid version manifest format");
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // 3. 查找匹配的版本条目，获取 version JSON URL
        NSString *versionJSONURL = nil;
        for (NSDictionary *v in versions) {
            if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:versionId]) {
                versionJSONURL = [v[@"url"] isKindOfClass:[NSString class]] ? v[@"url"] : nil;
                break;
            }
        }
        if (!versionJSONURL) {
            NSLog(@"[DownloadVC] Version %@ not found in manifest", versionId);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // BMCLAPI 镜像：替换 Mojang 官方域名
        if (useBMCLAPI) {
            versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                        withString:@"bmclapi2.bangbang93.com"];
            versionJSONURL = [versionJSONURL stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                                        withString:@"bmclapi2.bangbang93.com"];
        }

        // 4. 下载 version JSON
        NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
        if (!jsonURL) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSMutableURLRequest *jsonRequest = [NSMutableURLRequest requestWithURL:jsonURL];
        jsonRequest.timeoutInterval = 30.0;
        jsonRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        [jsonRequest setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];

        NSData *jsonData = [NSURLConnection sendSynchronousRequest:jsonRequest returningResponse:nil error:nil];
        if (!jsonData) {
            NSLog(@"[DownloadVC] Failed to download version JSON for %@", versionId);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        // 5. 创建版本目录并写入 JSON
        NSError *dirError = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:versionDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&dirError];
        if (dirError) {
            NSLog(@"[DownloadVC] Failed to create version dir: %@", dirError.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSError *writeErr = nil;
        if (![jsonData writeToFile:versionJsonPath options:NSDataWritingAtomic error:&writeErr]) {
            NSLog(@"[DownloadVC] Failed to write version JSON: %@", writeErr.localizedDescription);
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSLog(@"[DownloadVC] Vanilla version JSON saved: %@ (%lu bytes)", versionJsonPath, (unsigned long)jsonData.length);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
    });
}

/// 参照 FCL：安装模组加载器前，先完整安装对应的原版（version JSON + libraries + assets）。
/// 若原版已安装（versions/{id}/{id}.json 存在于 POJAV_GAME_DIR），直接 completion(YES)。
/// 否则：1) 确保 version JSON 存在；2) 用 MinecraftResourceDownloadTask 下载完整原版文件（库+资源）；
/// 3) 通过 InstallerProgressViewController 显示 FCL 风格进度。
/// 注：client.jar 由 Java 端启动时按需下载，此处不检查；MinecraftResourceDownloadTask
/// 下载时会对已存在且 SHA1 正确的文件跳过，因此重复调用安全。
- (void)ensureVanillaInstalled:(NSDictionary *)version completion:(void (^)(BOOL success))completion {
    if (![version isKindOfClass:[NSDictionary class]]) {
        if (completion) completion(NO);
        return;
    }
    NSString *versionId = version[@"id"];
    if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) {
        if (completion) completion(NO);
        return;
    }

    // 用 POJAV_GAME_DIR（与 MinecraftResourceDownloadTask 一致），而非 POJAV_HOME
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    if (gameDir.length == 0) {
        // 极端情况下环境变量缺失，回退到 POJAV_HOME
        gameDir = @(getenv("POJAV_HOME"));
    }
    NSString *versionJsonPath = [gameDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"versions/%@/%@.json", versionId, versionId]];

    // 1. 原版 JSON 已存在（说明之前已下载过原版），直接返回，避免重复下载。
    //   downloadVersion: 内部对已存在且 SHA1 正确的库/资源会自动跳过，无需此处逐一检查。
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        NSLog(@"[DownloadVC] Vanilla %@ already installed (JSON exists), skip preinstall", versionId);
        if (completion) completion(YES);
        return;
    }

    NSLog(@"[DownloadVC] Vanilla %@ not installed, preinstalling...", versionId);

    // 保存 completion，KVO 完成时调用
    __weak typeof(self) weakSelf = self;
    self.vanillaPreinstallCompletion = completion;

    // 2. 先确保 version JSON 存在（复用已有逻辑）
    [self ensureVanillaVersionJSONExists:versionId completion:^(BOOL jsonSuccess) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO);
            return;
        }
        if (!jsonSuccess) {
            strongSelf.vanillaPreinstallCompletion = nil;
            if (completion) completion(NO);
            return;
        }

        // 3. 创建 FCL 风格进度 VC 并 push
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) {
                if (completion) completion(NO);
                return;
            }
            InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
            progressVC.titleText = [NSString stringWithFormat:@"正在安装原版 %@", versionId];
            progressVC.stageMessage = @"正在准备下载原版文件...";
            progressVC.progress = -1; // 初始不确定模式，待拿到总字节数后切换为确定模式
            progressVC.cancelHandler = ^{
                __strong typeof(weakSelf) ss = weakSelf;
                if (!ss) return;
                if (ss.vanillaPreinstallTask) {
                    if (ss.isObservingVanillaPreinstall) {
                        [ss.vanillaPreinstallTask.progress removeObserver:ss forKeyPath:@"fractionCompleted"];
                        ss.isObservingVanillaPreinstall = NO;
                    }
                    [ss.vanillaPreinstallTask.progress cancel];
                    ss.vanillaPreinstallTask = nil;
                }
                ss.vanillaPreinstallProgressVC = nil;
                ss.vanillaPreinstallCompletion = nil;
            };
            s.vanillaPreinstallProgressVC = progressVC;
            [s.navigationController pushViewController:progressVC animated:YES];

            // 4. 创建下载任务
            MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
            task.maxRetryCount = 3;
            s.vanillaPreinstallTask = task;

            task.handleError = ^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) ss = weakSelf;
                    if (!ss) return;
                    if (ss.isObservingVanillaPreinstall) {
                        [ss.vanillaPreinstallTask.progress removeObserver:ss forKeyPath:@"fractionCompleted"];
                        ss.isObservingVanillaPreinstall = NO;
                    }
                    if (ss.vanillaPreinstallProgressVC && [ss.navigationController.viewControllers containsObject:ss.vanillaPreinstallProgressVC]) {
                        [ss.navigationController popViewControllerAnimated:YES];
                    }
                    ss.vanillaPreinstallTask = nil;
                    ss.vanillaPreinstallProgressVC = nil;
                    void (^cb)(BOOL) = ss.vanillaPreinstallCompletion;
                    ss.vanillaPreinstallCompletion = nil;
                    if (cb) cb(NO);
                });
            };

            // 5. KVO 监听进度（用独立 context 与主下载流程区分）
            [task.progress addObserver:s
                            forKeyPath:@"fractionCompleted"
                               options:NSKeyValueObservingOptionInitial
                               context:(void *)@"VanillaPreinstallContext"];
            s.isObservingVanillaPreinstall = YES;

            // 6. 后台线程启动下载
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                __strong typeof(weakSelf) ss = weakSelf;
                if (!ss) return;
                [ss.vanillaPreinstallTask downloadVersion:version];
            });
        });
    }];
}

#pragma mark - Vanilla Installation

- (void)downloadVanillaVersion:(NSDictionary *)version {
    if (![self isNetworkAvailable]) {
        [self showError:@"网络不可用，请检查网络连接"];
        return;
    }

    NSString *versionId = version[@"id"];

    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
    // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
    profile[@"gameDir"] = @".";
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;

    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;

    [self startVersionDownload:version];
}

- (void)startVersionDownload:(NSDictionary *)version {
    __weak DownloadViewController *weakSelf = self;

    // 在内容区显示下载状态，替代弹窗（点击查看详情，关闭按钮取消）
    self.downloadingAlert = [InlineMessageView showInViewController:self
                                                              title:@"下载中"
                                                           message:@"正在准备下载..."
                                                              type:InlineMessageTypeLoading
                                                  showsCloseButton:YES];
    // 点击消息体打开详情视图
    self.downloadingAlert.onTap = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.downloadTask) {
            strongSelf.progressVC = [[DownloadProgressViewController alloc] initWithTask:strongSelf.downloadTask];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:strongSelf.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [strongSelf presentViewController:nav animated:YES completion:nil];
        }
    };
    // 点击关闭按钮取消下载
    self.downloadingAlert.onClose = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.downloadTask) {
            if (strongSelf.isObservingProgress) {
                [strongSelf.downloadTask.progress removeObserver:strongSelf forKeyPath:@"fractionCompleted"];
                strongSelf.isObservingProgress = NO;
            }
            [strongSelf.downloadTask.progress cancel];
            strongSelf.downloadTask = nil;
        }
        strongSelf.view.userInteractionEnabled = YES;
        [strongSelf.loadingIndicator stopAnimating];
        [strongSelf.downloadingAlert dismiss];
        strongSelf.downloadingAlert = nil;
    };

    [self.loadingIndicator startAnimating];
    
    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;
    
    self.downloadTask.retryCallback = ^(NSInteger retryCount, NSInteger maxRetryCount) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.downloadingAlert) {
                [weakSelf.downloadingAlert updateMessage:[NSString stringWithFormat:@"下载失败，正在重试 (%ld/%ld)...", (long)retryCount, (long)maxRetryCount]];
            }
        });
    };

    self.downloadTask.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.isObservingProgress) {
                [weakSelf.downloadTask.progress removeObserver:weakSelf forKeyPath:@"fractionCompleted"];
                weakSelf.isObservingProgress = NO;
            }
            weakSelf.view.userInteractionEnabled = YES;
            [weakSelf.loadingIndicator stopAnimating];
            // 关闭下载中提示
            [weakSelf.downloadingAlert dismiss];
            weakSelf.downloadingAlert = nil;
            weakSelf.downloadTask = nil;
            weakSelf.progressVC = nil;

            [weakSelf showError:@"版本下载失败，请检查网络连接"];
        });
    };
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.downloadTask downloadVersion:version];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isObservingProgress) {
                [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
                self.isObservingProgress = NO;
            }
            [self.downloadTask.progress addObserver:self
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)@"DownloadProgressContext"];
            self.isObservingProgress = YES;
        });
    });
}

#pragma mark - Fabric Installation

- (void)installFabric:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI {
    [self installFabricLikeLoader:gameVersion loaderVersion:loaderVersion installAPI:installAPI vendor:@"fabric"];
}

- (void)installQuilt:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    // Quilt 不安装 Fabric API（用 QSL/QFAPI），强制 installAPI=NO
    [self installFabricLikeLoader:gameVersion loaderVersion:loaderVersion installAPI:NO vendor:@"quilt"];
}

/// Fabric/Quilt 共用的 meta API 安装实现
/// - vendor: @"fabric" 或 @"quilt"，决定 meta URL 与显示文案
- (void)installFabricLikeLoader:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI vendor:(NSString *)vendor {
    BOOL isQuilt = [vendor isEqualToString:@"quilt"];
    NSString *displayName = isQuilt ? @"Quilt" : @"Fabric";
    NSString *metaBase = isQuilt ? @"https://meta.quiltmc.org/v3/versions/loader"
                                 : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *loaderTag = isQuilt ? @"quilt" : @"fabric";

    // FCL 风格进度展示：push 一个进度 VC，替代转圈 alert
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在安装 %@", displayName];
    progressVC.progress = -1; // 不确定模式，正在拉取 profile JSON
    progressVC.stageMessage = [NSString stringWithFormat:@"正在获取 %@ profile...\n游戏版本: %@  加载器: %@", displayName, gameVersion, loaderVersion];
    self.installerProgressVC = progressVC;

    __weak typeof(self) weakSelf = self;
    __block NSURLSessionDataTask *dataTask = nil;
    progressVC.cancelHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (dataTask) [dataTask cancel];
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            strongSelf.installerProgressVC = nil;
        }
    };

    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *urlString = [NSString stringWithFormat:@"%@/%@/%@/profile/json", metaBase, gameVersion, loaderVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    // 注册到统一下载任务管理器
    NSString *source = getPrefObject(@"general.download_source") ?: @"official";
    NSString *fabricTaskName = [NSString stringWithFormat:@"%@-%@-%@", loaderTag, gameVersion, loaderVersion];
    DownloadTaskItem *fabricTaskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:fabricTaskName
                         displayName:[NSString stringWithFormat:@"%@ %@ (%@)", displayName, loaderVersion, gameVersion]
                      downloadSource:source
                             rawTask:nil
                      supportsResume:YES
                             iconURL:nil];
    __block NSString *fabricTaskId = fabricTaskItem.taskId;

    // profile JSON 较小，使用 dataTask；进度通过阶段驱动（无法精确测算）
    dataTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error) {
                if (error.code == NSURLErrorCancelled) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId state:DownloadTaskStateCancelled];
                } else {
                    NSError *err = [NSError errorWithDomain:@"FabricInstall" code:error.code userInfo:@{NSLocalizedDescriptionKey: error.localizedDescription ?: @"网络错误"}];
                    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                }
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"%@ 安装失败: %@", displayName, error.localizedDescription ?: @"网络错误"]];
                return;
            }

            if (!data) {
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:2 userInfo:@{NSLocalizedDescriptionKey: @"返回数据为空"}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"%@ 安装失败: 返回数据为空", displayName]];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:fabricTaskId progress:0.5 totalBytes:-1 downloadedBytes:0];

            // 解析 JSON
            strongSelf.installerProgressVC.progress = 0.5;
            strongSelf.installerProgressVC.stageMessage = [NSString stringWithFormat:@"正在解析 %@ 配置...", displayName];

            NSError *jsonError;
            NSDictionary *profileJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!profileJson || jsonError) {
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:3 userInfo:@{NSLocalizedDescriptionKey: jsonError.localizedDescription ?: @"解析失败"}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"解析 %@ 配置失败", displayName]];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:fabricTaskId progress:0.7 totalBytes:-1 downloadedBytes:0];

            // 写入版本 JSON
            strongSelf.installerProgressVC.progress = 0.7;
            strongSelf.installerProgressVC.stageMessage = @"正在写入版本文件...";

            NSString *versionId = profileJson[@"id"];
            NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];
            [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];

            NSError *saveError;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:NSJSONWritingPrettyPrinted error:&saveError];
            [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError];
            if (saveError) {
                NSError *err = [NSError errorWithDomain:@"FabricInstall" code:4 userInfo:@{NSLocalizedDescriptionKey: saveError.localizedDescription}];
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"保存配置失败: %@", saveError.localizedDescription]];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:fabricTaskId progress:0.85 totalBytes:-1 downloadedBytes:0];

            // 注册 profile
            strongSelf.installerProgressVC.progress = 0.85;
            strongSelf.installerProgressVC.stageMessage = @"正在注册配置...";

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            // 改回原来的"游戏目录切换"机制：所有版本共享根目录（gameDir="."）
            // 用户通过设置中的"游戏目录切换"功能手动切换不同的 gameDir
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            // 仅 Fabric 安装 Fabric API；Quilt 用 QSL/QFAPI，不安装
            if (installAPI && !isQuilt) {
                strongSelf.installerProgressVC.progress = 0.9;
                strongSelf.installerProgressVC.stageMessage = @"正在下载 Fabric API...";
                [strongSelf downloadFabricAPI:gameVersion completion:^(BOOL success, NSError *apiError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (success) {
                            [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                            [strongSelf2 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"%@ %@ 安装成功\nFabric API 已自动安装", displayName, loaderVersion]];
                        } else {
                            NSError *err = [NSError errorWithDomain:@"FabricInstall" code:5 userInfo:@{NSLocalizedDescriptionKey: apiError.localizedDescription ?: @"Fabric API 下载失败"}];
                            [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:err];
                            [strongSelf2 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"%@ %@ 安装成功\nFabric API 安装失败: %@", displayName, loaderVersion, apiError.localizedDescription ?: @"未知错误"]];
                        }
                    });
                }];
            } else {
                [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId completedWithError:nil];
                [strongSelf finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"%@ %@ 安装成功", displayName, loaderVersion]];
            }
        });
    }];
    fabricTaskItem.rawTask = dataTask;
    [[DownloadTaskManager sharedManager] setTaskWithId:fabricTaskId state:DownloadTaskStateDownloading];
    [dataTask resume];
}

// 安装进度 VC 完成时的统一处理：进度满 → 短暂展示 → pop 并显示成功提示
- (void)finishInstallerProgressWithSuccess:(NSString *)message {
    if (!self.installerProgressVC) return;
    self.installerProgressVC.progress = 1.0;
    self.installerProgressVC.stageMessage = @"安装完成";
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.navigationController popViewControllerAnimated:YES];
        strongSelf.installerProgressVC = nil;
        [strongSelf showSuccessMessage:message];
    });
}

// 安装进度 VC 失败时的统一处理：显示错误 → pop
- (void)finishInstallerProgressWithError:(NSString *)errorMessage {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.installerProgressVC) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            strongSelf.installerProgressVC = nil;
        }
        [strongSelf showError:errorMessage];
    });
}

- (void)downloadFabricAPI:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"version"] = gameVersion;
    
    __weak typeof(self) weakSelf = self;
    id api = [self currentAPIForTabType:@"mod"];
    [api searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) completion(NO, [NSError errorWithDomain:@"AppError" code:-1 userInfo:nil]);
            return;
        }
        if (error || results.count == 0) {
            if (completion) completion(NO, error ?: [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"未找到 Fabric API"}]);
            return;
        }
        
        NSDictionary *fabricAPI = nil;
        for (NSDictionary *mod in results) {
            NSString *title = mod[@"title"] ?: @"";
            if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                fabricAPI = mod;
                break;
            }
        }
        
        if (!fabricAPI) {
            if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"未找到合适的 Fabric API 版本"}]);
            return;
        }
        
        [api getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
            if (versionError || versions.count == 0) {
                if (completion) completion(NO, versionError ?: [NSError errorWithDomain:@"DownloadError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"获取 Fabric API 版本失败"}]);
                return;
            }
            
            ModVersion *matchingVersion = nil;
            for (ModVersion *ver in versions) {
                if ([ver.gameVersions containsObject:gameVersion]) {
                    matchingVersion = ver;
                    break;
                }
            }
            
            if (!matchingVersion) {
                matchingVersion = versions.firstObject;
            }
            
            [strongSelf downloadModVersion:matchingVersion modInfo:fabricAPI completion:completion];
        }];
    }];
}

#pragma mark - Forge Installation

- (LauncherNavigationController *)activeLauncherNavigationController {
    // First try the existing logic
    UISplitViewController *splitVC = self.splitViewController;
    if (!splitVC && [self.presentingViewController isKindOfClass:[UISplitViewController class]]) {
        splitVC = (UISplitViewController *)self.presentingViewController;
    }
    if (splitVC.viewControllers.count > 1) {
        UIViewController *candidate = splitVC.viewControllers[1];
        if ([candidate isKindOfClass:[LauncherNavigationController class]]) {
            return (LauncherNavigationController *)candidate;
        }
        if ([candidate isKindOfClass:[UINavigationController class]]) {
            for (UIViewController *vc in ((UINavigationController *)candidate).viewControllers) {
                if ([vc isKindOfClass:[LauncherNavigationController class]]) {
                    return (LauncherNavigationController *)vc;
                }
            }
        }
    }
    if ([self.navigationController isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)self.navigationController;
    }

    // Fallback: traverse from key window root view controller
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                keyWindow = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!keyWindow) {
        keyWindow = [[UIApplication sharedApplication] windows].firstObject;
    }

    UIViewController *rootVC = keyWindow.rootViewController;
    if (rootVC) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:rootVC];
        if (found) return found;
    }

    return nil;
}

- (LauncherNavigationController *)findLauncherNavigationControllerIn:(UIViewController *)vc {
    if ([vc isKindOfClass:[LauncherNavigationController class]]) {
        return (LauncherNavigationController *)vc;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in ((UINavigationController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in ((UISplitViewController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in ((UITabBarController *)vc).viewControllers) {
            LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
            if (found) return found;
        }
    }
    if (vc.presentedViewController) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:vc.presentedViewController];
        if (found) return found;
    }
    for (UIViewController *child in vc.childViewControllers) {
        LauncherNavigationController *found = [self findLauncherNavigationControllerIn:child];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Mod Installer (Fallback when LauncherNavigationController is not available)

- (void)launchModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) {
        // 解析失败（manifest 缺失/主类非法）时明确提示，避免静默 return 让用户以为安装器已启动
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:@"无法解析安装器主类或 Java 版本：%@", path.lastPathComponent]);
        return;
    }
    // execute_jar 路径：Caciocavallo17 jar 现已统一为 Java 17 编译版本，
    // Java 17/21 均可加载，不再需要强制提升 requiredJavaVersion 到 25。
    // - Java 8 JAR（如 OptiFine 安装器）走 Caciocavallo（非 17）路径，用 Java 8
    // - Java 17+ JAR 走 Caciocavallo17 路径，用 Java 17/21 即可
    // 与 JavaLauncher.m launchJar 分支保持一致。
    int requiredJavaVersion = vc.requiredJavaVersion;
    // 预检 execute_jar 标签的 JRE 是否已配置，避免 present 后才发现没 JRE 导致黑屏
    // 与 LauncherRightPanelViewController.enterModInstallerWithPath: 行为一致
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        showDialog(localize(@"Error", nil),
            [NSString stringWithFormat:@"执行 JAR 需要 Java %d 或更高版本，但未配置对应的运行时。\n\n请到「设置 → 管理运行时」中为「执行 Jar」标签分配一个 Java %d+ 的运行时。", requiredJavaVersion, requiredJavaVersion]);
        return;
    }
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"com.apple.private.local.sandboxed-jit");
    
    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    }
    
    // 在内容区显示 JIT 等待提示，替代弹窗
    InlineMessageView *jitAlert = [InlineMessageView showInViewController:self
                                                                    title:localize(@"launcher.wait_jit.title", nil)
                                                                 message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
                                                                    type:InlineMessageTypeLoading];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [jitAlert dismiss];
            if (handler) handler();
        });
    });
}

- (void)handleInstallerDownloadResultWithVendorName:(NSString *)vendorName
                                        gameVersion:(NSString *)gameVersion
                                        profileName:(NSString *)profileName
                                    resultOrError:(id)resultOrError
                                     installAction:(void (^)(void))installAction {
    if ([resultOrError isKindOfClass:[NSError class]]) {
        NSError *error = (NSError *)resultOrError;
        if ([error.domain isEqualToString:ForgeInstallerFlowErrorDomain] && error.code == ForgeInstallerFlowErrorCodeCancelled) {
            return;
        }
        [self showError:error.localizedDescription ?: [NSString stringWithFormat:@"%@ 安装失败", vendorName]];
        return;
    }
    
    NSString *filePath = nil;
    if ([resultOrError isKindOfClass:[NSDictionary class]]) {
        filePath = ((NSDictionary *)resultOrError)[@"filePath"];
    } else if ([resultOrError isKindOfClass:[NSString class]]) {
        filePath = (NSString *)resultOrError;
    }
    if (filePath.length == 0) {
        [self showError:[NSString stringWithFormat:@"%@ 安装器下载结果无效", vendorName]];
        return;
    }
    
    LauncherNavigationController *navVC = [self activeLauncherNavigationController];
    
    NSString *message = [NSString stringWithFormat:@"%@ 安装器已下载，正在启动。安装完成后请按提示操作。", vendorName];
    
    void (^launchInstaller)(void) = ^{
        if (navVC) {
            [navVC enterModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
        } else {
            [self launchModInstallerWithPath:filePath hitEnterAfterWindowShown:YES];
        }
        
        if (installAction) {
            installAction();
        } else {
            [self showSuccessMessage:[NSString stringWithFormat:@"%@ 安装器已启动\n配置文件: %@", vendorName, profileName ?: gameVersion]];
        }
    };
    
    void (^showAlertAndLaunch)(void) = ^{
        // 在内容区显示下载完成提示，替代弹窗
        InlineMessageView *msgView = [InlineMessageView showInViewController:self
                                                                       title:@"下载完成"
                                                                    message:message
                                                                       type:InlineMessageTypeSuccess];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [msgView dismiss];
            if (launchInstaller) launchInstaller();
        });
    };

    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:showAlertAndLaunch];
    } else {
        showAlertAndLaunch();
    }
}

- (void)installForge:(NSString *)gameVersion installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
    forgeVC.gameVersion = gameVersion;
    // ModLoaderInstallViewController 已选好版本，传入以跳过重复的版本列表 UI
    forgeVC.presetVersionString = loaderVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 解析 ForgeInstallViewController 打包的回调结果（无论成败都需要先解析）
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        // 先 pop 掉 ForgeInstallViewController；pop 完成后再走后续流程，
        // 否则在 pop 动画期间 present alert / push 进度页会失败或弹错 VC
        void (^continuation)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!success) {
                [strongSelf2 handleInstallerDownloadResultWithVendorName:@"Forge"
                                                              gameVersion:gameVersion
                                                              profileName:profileName
                                                            resultOrError:resultOrError
                                                             installAction:nil];
                return;
            }

            if (selectedScheme == 1 && filePath.length > 0) {
                // 直装方案：push 进度 VC，由 ForgeDirectInstaller 的 progress 回调驱动
                NSLog(@"[ForgeDirect] DownloadViewController: starting direct install with progress UI");
                InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
                progressVC.titleText = @"Forge 直装中";
                progressVC.progress = 0.0;
                progressVC.stageMessage = @"准备中...";
                strongSelf2.installerProgressVC = progressVC;
                [strongSelf2.navigationController pushViewController:progressVC animated:YES];

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *directError = nil;
                    BOOL installed = [ForgeDirectInstaller installForgeFromInstaller:filePath
                                                                           versionId:profileName
                                                                             progress:^(double progress, NSString *stageMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) strongSelf3 = weakSelf;
                            if (!strongSelf3 || !strongSelf3.installerProgressVC) return;
                            strongSelf3.installerProgressVC.progress = progress;
                            NSString *stage = stageMessage ?: @"";
                            strongSelf3.installerProgressVC.stageMessage = [NSString stringWithFormat:@"%@ - %.0f%%", stage, progress * 100];
                        });
                    }
                                                                               error:&directError];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf3 = weakSelf;
                        if (!strongSelf3) return;
                        if (!installed) {
                            [strongSelf3 finishInstallerProgressWithError:[NSString stringWithFormat:@"Forge 直装失败: %@", directError.localizedDescription ?: @"未知错误"]];
                            return;
                        }
                        // 直装成功后，若用户勾选了 OptiFine，继续下载（之前的实现这里直接 return 漏掉了 OptiFine）
                        if (installOptiFine) {
                            strongSelf3.installerProgressVC.stageMessage = @"正在下载 OptiFine...";
                            strongSelf3.installerProgressVC.progress = -1; // OptiFine 下载无法精确测算，进入不确定模式
                            [strongSelf3 downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    __strong typeof(weakSelf) strongSelf4 = weakSelf;
                                    if (!strongSelf4) return;
                                    if (optiSuccess) {
                                        [strongSelf4 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Forge 直装成功\nOptiFine 已自动安装\n配置文件: %@", profileName ?: gameVersion]];
                                    } else {
                                        [strongSelf4 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Forge 直装成功\nOptiFine 安装失败: %@\n配置文件: %@", optiError.localizedDescription ?: @"未知错误", profileName ?: gameVersion]];
                                    }
                                });
                            }];
                        } else {
                            [strongSelf3 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"Forge 直装成功\n配置文件: %@", profileName ?: gameVersion]];
                        }
                    });
                });
                return;
            }

            // 原版方案（运行安装器）：进入 AWT 安装器 GUI 流程
            [strongSelf2 handleInstallerDownloadResultWithVendorName:@"Forge"
                                                          gameVersion:gameVersion
                                                          profileName:profileName
                                                        resultOrError:resultOrError
                                                         installAction:^{
                if (installOptiFine) {
                    [strongSelf2 downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (optiSuccess) {
                                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge 安装器已启动\nOptiFine 已自动安装\n配置文件: %@", profileName ?: gameVersion]];
                            } else {
                                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge 安装器已启动\nOptiFine 安装失败: %@\n配置文件: %@", optiError.localizedDescription ?: @"未知错误", profileName ?: gameVersion]];
                            }
                        });
                    }];
                } else {
                    [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge 安装器已启动\n配置文件: %@", profileName ?: gameVersion]];
                }
            }];
        };

        if (strongSelf.navigationController.topViewController != strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            // 等待 pop 动画结束后再触发后续 present / push，避免动画冲突
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), continuation);
        } else {
            continuation();
        }
    };
    forgeVC.completionHandler = completion;

    // 直接 push 到中间内容区，不再用 FormSheet 弹窗
    [self.navigationController pushViewController:forgeVC animated:YES];
}

- (void)downloadOptiFine:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 修复: 不再依赖硬编码的版本映射表（容易过期），改用 BMCLAPI 动态查询游戏版本对应的最新 OptiFine 版本
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:&listError];
        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                // 取列表中第一个（通常为最新发布版本）
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        // fallback: 列表 API 失败时回退到本地硬编码映射
        if (!optiFinePatch) {
            NSString *mapped = [self mapGameVersionToOptiFine:gameVersion];
            if (mapped) {
                // 映射表里是 "HD_U_I6" 形式，拆出 type=HD_U, patch=I6
                NSRange range = [mapped rangeOfString:@"_"];
                if (range.location != NSNotFound) {
                    optiFineType = [mapped substringToIndex:range.location];
                    optiFinePatch = [mapped substringFromIndex:range.location + 1];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"不支持的 OptiFine 版本: %@ (BMCLAPI 列表查询失败且无本地映射)", gameVersion]}]);
            });
            return;
        }

        // BMCLAPI OptiFine 下载 URL: /optifine/{mcversion}/{type}/{patch}
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@",
                                 gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *data = [NSData dataWithContentsOfURL:dlURL options:NSDataReadingUncached error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [NSData dataWithContentsOfURL:officialURLObject options:NSDataReadingUncached error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        if (!data || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *errDesc = downloadError.localizedDescription;
                if (downloadError.code == NSURLErrorFileDoesNotExist || [errDesc containsString:@"404"]) {
                    errDesc = [NSString stringWithFormat:@"OptiFine %@ %@ 在 BMCLAPI 镜像中不存在 (404)。该游戏版本可能尚未发布 OptiFine。", optiFineType, optiFinePatch];
                }
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: errDesc ?: @"下载 OptiFine 失败"}]);
            });
            return;
        }

        NSString *modsDir = [self currentInstanceModsPath];
        // 优先用 API 返回的 filename；否则用 type_patch 构造
        NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
        NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

        NSError *saveError;
        BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&saveError];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success, saveError);
        });
    });
}

- (NSString *)mapGameVersionToOptiFine:(NSString *)gameVersion {
    NSDictionary *versionMap = @{
        @"1.21.4": @"HD_U_J3",
        @"1.21.3": @"HD_U_J2",
        @"1.21.1": @"HD_U_J1",
        @"1.21": @"HD_U_I9",
        @"1.20.4": @"HD_U_I7",
        @"1.20.2": @"HD_U_I6",
        @"1.20.1": @"HD_U_I6",
        @"1.20": @"HD_U_I5",
        @"1.19.4": @"HD_U_I4",
        @"1.19.3": @"HD_U_I3",
        @"1.19.2": @"HD_U_H9",
        @"1.18.2": @"HD_U_H7",
        @"1.17.1": @"HD_U_H1",
        @"1.16.5": @"HD_U_G8",
        @"1.16.4": @"HD_U_G7",
        @"1.15.2": @"HD_U_G6",
        @"1.14.4": @"HD_U_G5",
        @"1.12.2": @"HD_U_G5",
        @"1.8.9": @"HD_U_L5",
    };
    
    NSString *optiFineVersion = versionMap[gameVersion];
    if (optiFineVersion) return optiFineVersion;
    
    for (NSString *key in versionMap) {
        if ([gameVersion hasPrefix:key]) {
            return versionMap[key];
        }
    }
    
    return nil;
}

#pragma mark - OptiFine as Patch Installation (单独安装，参照 FCL OptiFineInstallTask)

/// 单独安装 OptiFine 作为版本补丁（不依赖 Forge）
/// loaderVersion 是 packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
- (void)installOptiFineAsPatch:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    // 解析 packed 格式
    NSArray *parts = [loaderVersion componentsSeparatedByString:@"\x1f"];
    if (parts.count < 3) {
        [self showError:@"OptiFine 版本信息无效"];
        return;
    }
    NSString *optiType = parts[0];
    NSString *optiPatch = parts[1];
    NSString *filename = parts[2];

    NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiType, optiPatch];

    // push 进度 VC
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = @"正在安装 OptiFine";
    progressVC.progress = -1;
    progressVC.stageMessage = [NSString stringWithFormat:@"正在下载 OptiFine %@_%@...", optiType, optiPatch];
    self.installerProgressVC = progressVC;

    __weak typeof(self) weakSelf = self;
    progressVC.cancelHandler = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            strongSelf.installerProgressVC = nil;
        }
    };

    [self.navigationController pushViewController:progressVC animated:YES];

    // 注册到下载任务管理器
    NSString *source = getPrefObject(@"general.download_source") ?: @"official";
    NSString *taskName = [NSString stringWithFormat:@"optifine-%@-%@-%@", gameVersion, optiType, optiPatch];
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:taskName
                         displayName:[NSString stringWithFormat:@"OptiFine %@_%@ (%@)", optiType, optiPatch, gameVersion]
                      downloadSource:source
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    __block NSString *taskId = taskItem.taskId;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. 下载 OptiFine jar
        NSString *bmclURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiType, optiPatch];
        NSURL *url = [NSURL URLWithString:bmclURL];
        NSError *downloadError = nil;
        NSData *jarData = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:&downloadError];

        // fallback 官方源
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [NSData dataWithContentsOfURL:officialURLObject options:NSDataReadingUncached error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:1 userInfo:@{NSLocalizedDescriptionKey: downloadError.localizedDescription ?: @"下载 OptiFine 失败"}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"下载 OptiFine 失败: %@", downloadError.localizedDescription ?: @"未知错误"]];
            });
            return;
        }

        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId progress:0.5 totalBytes:-1 downloadedBytes:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.installerProgressVC.progress = 0.5;
            strongSelf.installerProgressVC.stageMessage = @"正在写入版本文件...";
        });

        // 2. 创建版本目录
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];

        // 3. 写入 jar 文件作为 client.jar
        // 对于 1.14+ OptiFine，安装器 jar 本身就是 patched client.jar，可以直接使用
        // 对于 1.13- OptiFine，安装器 jar 含 Patcher，但 iOS 无法运行 Patcher，
        //   降级方案：直接使用安装器 jar 作为 client.jar（部分老版本可能无法启动，提示用户）
        NSString *jarPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jar", versionId]];
        NSError *writeError = nil;
        [jarData writeToFile:jarPath options:NSDataWritingAtomic error:&writeError];
        if (writeError) {
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:2 userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:[NSString stringWithFormat:@"写入 OptiFine jar 失败: %@", writeError.localizedDescription]];
            });
            return;
        }

        // 4. 创建 version.json（使用 inheritsFrom 继承 vanilla 元数据，参照 FCL OptiFineInstallTask）
        // OptiFine jar 作为 client.jar（jar 字段指向 versionId）
        // mainClass 用标准 vanilla 入口，启动器会从 OptiFine jar 内加载 net.minecraft.client.main.Main
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,  // 继承 vanilla 版本的 assets/libraries/arguments
            @"type": @"release",
            @"mainClass": @"net.minecraft.client.main.Main",
            @"libraries": @[],
            @"jar": versionId,
            @"minimumLauncherVersion": @21
        };
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:nil];

        // 4.1 确保父版本（vanilla）的 version JSON 已存在
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            // 父版本不存在，提示用户先安装原版
            NSError *err = [NSError errorWithDomain:@"OptiFineInstall" code:3
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未找到原版 %@ 的版本信息。请先在下载页面安装原版 %@，然后再安装 OptiFine。", gameVersion, gameVersion]}];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:err];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishInstallerProgressWithError:err.localizedDescription];
            });
            return;
        }

        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId progress:0.85 totalBytes:-1 downloadedBytes:0];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.installerProgressVC.progress = 0.85;
            strongSelf.installerProgressVC.stageMessage = @"正在注册配置...";
        });

        // 5. 注册 profile
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [[DownloadTaskManager sharedManager] setTaskWithId:taskId completedWithError:nil];
            [strongSelf finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"OptiFine 安装成功\n版本: %@\n配置文件: %@", versionId, versionId]];
        });
    });
}

#pragma mark - NeoForge Installation

- (void)installNeoForge:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion {
    ForgeInstallViewController *neoForgeVC = [[ForgeInstallViewController alloc] init];
    neoForgeVC.gameVersion = gameVersion;
    neoForgeVC.isNeoForge = YES;
    // ModLoaderInstallViewController 已选好版本，传入以跳过重复的版本列表 UI
    neoForgeVC.presetVersionString = loaderVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 解析 ForgeInstallViewController 打包的回调结果（无论成败都需要先解析）
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        // 先 pop 掉 NeoForge 安装器选择页；pop 完成后再走后续流程，避免动画期间 present/push 失败
        void (^continuation)(void) = ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!success) {
                [strongSelf2 handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                              gameVersion:gameVersion
                                                              profileName:profileName
                                                            resultOrError:resultOrError
                                                             installAction:nil];
                return;
            }

            if (selectedScheme == 1 && filePath.length > 0) {
                // 直装方案：push 进度 VC，由 NeoForgeDirectInstaller 的 progress 回调驱动
                NSLog(@"[NeoForgeDirect] DownloadViewController: starting direct install with progress UI");
                InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
                progressVC.titleText = @"NeoForge 直装中";
                progressVC.progress = 0.0;
                progressVC.stageMessage = @"准备中...";
                strongSelf2.installerProgressVC = progressVC;
                [strongSelf2.navigationController pushViewController:progressVC animated:YES];

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *directError = nil;
                    BOOL installed = [NeoForgeDirectInstaller installNeoForgeFromInstaller:filePath
                                                                                   versionId:profileName
                                                                                    progress:^(double progress, NSString *stageMessage) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            __strong typeof(weakSelf) strongSelf3 = weakSelf;
                            if (!strongSelf3 || !strongSelf3.installerProgressVC) return;
                            strongSelf3.installerProgressVC.progress = progress;
                            NSString *stage = stageMessage ?: @"";
                            strongSelf3.installerProgressVC.stageMessage = [NSString stringWithFormat:@"%@ - %.0f%%", stage, progress * 100];
                        });
                    }
                                                                                       error:&directError];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf3 = weakSelf;
                        if (!strongSelf3) return;
                        if (installed) {
                            [strongSelf3 finishInstallerProgressWithSuccess:[NSString stringWithFormat:@"NeoForge 直装成功\n配置文件: %@", profileName ?: gameVersion]];
                        } else {
                            [strongSelf3 finishInstallerProgressWithError:[NSString stringWithFormat:@"NeoForge 直装失败: %@", directError.localizedDescription ?: @"未知错误"]];
                        }
                    });
                });
                return;
            }

            // 原版方案（运行安装器）
            [strongSelf2 handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                          gameVersion:gameVersion
                                                          profileName:profileName
                                                        resultOrError:resultOrError
                                                         installAction:^{
                [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"NeoForge 安装器已启动\n配置文件: %@", profileName ?: gameVersion]];
            }];
        };

        if (strongSelf.navigationController.topViewController != strongSelf) {
            [strongSelf.navigationController popViewControllerAnimated:YES];
            // 等待 pop 动画结束后再触发后续 present / push，避免动画冲突
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), continuation);
        } else {
            continuation();
        }
    };
    neoForgeVC.completionHandler = completion;

    // 直接 push 到中间内容区，不再用 FormSheet 弹窗
    [self.navigationController pushViewController:neoForgeVC animated:YES];
}

- (void)showSuccessMessage:(NSString *)message {
    // 在内容区显示成功提示，替代弹窗
    [InlineMessageView showInViewController:self
                                       title:@"安装成功"
                                    message:message
                                       type:InlineMessageTypeSuccess];
}

#pragma mark - Mod Download Helper (Shared)

- (void)downloadModVersion:(ModVersion *)version modInfo:(NSDictionary *)modInfo completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *downloadURL = version.primaryFile[@"url"];
    NSString *filename = version.primaryFile[@"filename"];
    
    if (!downloadURL || downloadURL.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"无效的下载链接"}]);
        return;
    }
    
    NSString *modsDir = [self currentInstanceModsPath];
    NSString *savePath = [modsDir stringByAppendingPathComponent:filename];
    
    NSURL *url = [NSURL URLWithString:downloadURL];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            if (completion) completion(NO, error);
            return;
        }
        
        [[NSFileManager defaultManager] removeItemAtPath:savePath error:nil];
        NSError *moveError;
        [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:savePath error:&moveError];
        
        if (completion) completion(moveError == nil, moveError);
    }];
    
    [downloadTask resume];
}

#pragma mark - Modpack Installation

- (void)openImportModpackView {
    // 修复: 改为 push 到中间内容区，与其他下载子流程一致，不再 FormSheet 弹窗
    ModpackImportViewController *importVC = [[ModpackImportViewController alloc] init];
    [self.navigationController pushViewController:importVC animated:YES];
}

- (void)installModpack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self installModpackAtIndexPath:indexPath];
}

- (void)installModpackAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *modpack = self.modpackList[indexPath.row];

    // 仿 FCL/ZL2：整合包也使用独立的版本选择页（复用 ModVersionViewController + AssetDetailHeaderView）
    // 替代原有的 ActionSheet 选版本方式，补齐项目封面图/描述/作者/下载量/标签等信息显示
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:modpack];

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;

    // 标记当前为整合包下载类型，版本选择回调时走整合包安装流程（而非 Mod 下载流程）
    self.pendingDownloadType = @"modpack";
    self.pendingModpackDict = modpack;

    // 在中间内容区 push 显示，与 Mod/Shader/ResourcePack 等保持一致的交互
    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)startModpackInstallation:(ModVersion *)version modpack:(NSDictionary *)modpack {
    NSString *downloadURL = version.primaryFile[@"url"];
    if (!downloadURL) {
        [self showError:@"无效的下载链接"];
        return;
    }

    // 修复: 改为 push 进度 VC (FCL 风格)，替代转圈 alert
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在下载整合包 %@", modpack[@"title"] ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在下载整合包文件...";
    [self.navigationController pushViewController:progressVC animated:YES];

    NSURL *url = [NSURL URLWithString:downloadURL];
    NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
    __block DownloadTaskItem *taskItem = nil;
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (error.code == NSURLErrorCancelled) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateCancelled];
                } else {
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:error];
                }
                [self.navigationController popViewControllerAnimated:YES];
                [self showError:error.localizedDescription];
                return;
            }
            // 移动到临时文件
            NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@_%@.mrpack", modpack[@"id"] ?: @"modpack", [[NSUUID UUID] UUIDString]]];
            [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
            NSError *moveError = nil;
            [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:tempPath error:&moveError];
            if (moveError) {
                [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:moveError];
                [self.navigationController popViewControllerAnimated:YES];
                [self showError:moveError.localizedDescription];
                return;
            }

            [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId completedWithError:nil];

            // 复用 ModpackImportService 完成解析和导入
            progressVC.progress = 0.1;
            progressVC.stageMessage = @"正在解析整合包...";
            ModpackImportService *importService = [[ModpackImportService alloc] init];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSError *parseError = nil;
                NSDictionary *modpackInfo = [importService parseModpackAtURL:[NSURL fileURLWithPath:tempPath] error:&parseError];
                if (!modpackInfo) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.navigationController popViewControllerAnimated:YES];
                        [self showError:parseError.localizedDescription ?: @"解析整合包失败"];
                    });
                    return;
                }
                // 用在线 modpack 信息补充 (title、icon 等)
                NSMutableDictionary *mutableInfo = [modpackInfo mutableCopy];
                if (!mutableInfo[@"name"] || [mutableInfo[@"name"] isEqualToString:[tempPath.lastPathComponent stringByDeletingPathExtension]]) {
                    mutableInfo[@"name"] = modpack[@"title"] ?: mutableInfo[@"name"];
                }
                if (modpack[@"imageUrl"]) {
                    // 不强制下载 icon，保留原整合包内的
                }

                NSError *importError = nil;
                BOOL success = [importService importModpack:mutableInfo
                                                   progress:^(double p, NSString *stage) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        progressVC.progress = p;
                        progressVC.stageMessage = stage;
                    });
                } error:&importError];

                // 清理临时文件
                [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

                dispatch_async(dispatch_get_main_queue(), ^{
                    if (success) {
                        progressVC.progress = 1.0;
                        progressVC.stageMessage = @"安装完成";
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [self.navigationController popViewControllerAnimated:YES];
                            NSString *loader = mutableInfo[@"loader"];
                            NSString *msg = [NSString stringWithFormat:@"整合包 %@ 安装完成", mutableInfo[@"name"]];
                            if ([loader isEqualToString:@"Forge"] || [loader isEqualToString:@"NeoForge"]) {
                                msg = [msg stringByAppendingFormat:@"\n\n注意: 此整合包使用 %@ %@ 加载器，请先通过下载界面手动安装该加载器版本。", loader, mutableInfo[@"loaderVersion"]];
                            }
                            [self showSuccessMessage:msg];
                        });
                    } else {
                        [self.navigationController popViewControllerAnimated:YES];
                        [self showError:importError.localizedDescription ?: @"导入失败"];
                    }
                });
            });
        });
    }];

    taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModpack
                        resourceName:modpack[@"title"] ?: @"modpack"
                         displayName:modpack[@"title"] ?: @"整合包"
                      downloadSource:downloadSource
                             rawTask:task
                      supportsResume:YES
                             iconURL:modpack[@"imageUrl"]];
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

    [task resume];
}

- (void)installModpackFromFile:(NSString *)filePath modpack:(NSDictionary *)modpack {
    // 修复: 此方法已废弃，在线下载流程改用 startModpackInstallation:modpack: 统一走 ModpackImportService
    // 保留以防其他地方调用，但内部也走 ModpackImportService
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = @"正在导入整合包";
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在解析整合包...";
    [self.navigationController pushViewController:progressVC animated:YES];

    ModpackImportService *importService = [[ModpackImportService alloc] init];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *parseError = nil;
        NSDictionary *modpackInfo = [importService parseModpackAtURL:[NSURL fileURLWithPath:filePath] error:&parseError];
        if (!modpackInfo) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.navigationController popViewControllerAnimated:YES];
                [self showError:parseError.localizedDescription ?: @"解析失败"];
            });
            return;
        }
        NSError *importError = nil;
        BOOL success = [importService importModpack:modpackInfo
                                           progress:^(double p, NSString *stage) {
            dispatch_async(dispatch_get_main_queue(), ^{
                progressVC.progress = p;
                progressVC.stageMessage = stage;
            });
        } error:&importError];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                progressVC.progress = 1.0;
                progressVC.stageMessage = @"导入完成";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self.navigationController popViewControllerAnimated:YES];
                    [self showSuccessMessage:[NSString stringWithFormat:@"整合包 %@ 导入完成", modpackInfo[@"name"]]];
                });
            } else {
                [self.navigationController popViewControllerAnimated:YES];
                [self showError:importError.localizedDescription ?: @"导入失败"];
            }
        });
    });
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) {
        return self.modList.count + (self.hasMoreMods ? 1 : 0);
    } else if (tableView == self.shaderTableView) {
        return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    } else if (tableView == self.modpackTableView) {
        return self.modpackList.count + (self.hasMoreModpacks ? 1 : 0);
    } else if (tableView == self.resourcepackTableView) {
        return self.resourcepackList.count + (self.hasMoreResourcepacks ? 1 : 0);
    } else if (tableView == self.datapackTableView) {
        return self.datapackList.count + (self.hasMoreDatapacks ? 1 : 0);
    } else if (tableView == self.worldTableView) {
        return self.worldList.count + (self.hasMoreWorlds ? 1 : 0);
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.modpackTableView && indexPath.row == self.modpackList.count && self.hasMoreModpacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.resourcepackTableView && indexPath.row == self.resourcepackList.count && self.hasMoreResourcepacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.datapackTableView && indexPath.row == self.datapackList.count && self.hasMoreDatapacks) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    if (tableView == self.worldTableView && indexPath.row == self.worldList.count && self.hasMoreWorlds) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }

    ModernAssetCell *cell;
    if (tableView == self.modTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
        NSDictionary *mod = self.modList[indexPath.row];
        [cell configureWithMod:mod];
        [cell.downloadButton addTarget:self action:@selector(downloadMod:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.shaderTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
        NSDictionary *shader = self.shaderList[indexPath.row];
        [cell configureWithShader:shader];
        [cell.downloadButton addTarget:self action:@selector(downloadShader:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.resourcepackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ResourcepackCell" forIndexPath:indexPath];
        NSDictionary *resourcepack = self.resourcepackList[indexPath.row];
        [cell configureWithResourcepack:resourcepack];
        [cell.downloadButton addTarget:self action:@selector(downloadResourcepack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.datapackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"DatapackCell" forIndexPath:indexPath];
        NSDictionary *datapack = self.datapackList[indexPath.row];
        [cell configureWithDatapack:datapack];
        [cell.downloadButton addTarget:self action:@selector(downloadDatapack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.worldTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"WorldCell" forIndexPath:indexPath];
        NSDictionary *world = self.worldList[indexPath.row];
        [cell configureWithWorld:world];
        [cell.downloadButton addTarget:self action:@selector(downloadWorld:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
        NSDictionary *modpack = self.modpackList[indexPath.row];
        [cell configureWithModpack:modpack];
        [cell.downloadButton addTarget:self action:@selector(installModpack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView && indexPath.row == self.modList.count - 5 && self.hasMoreMods && !self.isLoadingMore) {
        [self loadModList];
    }

    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count - 5 && self.hasMoreShaders && !self.isLoadingMore) {
        [self loadShaderList];
    }

    if (tableView == self.modpackTableView && indexPath.row == self.modpackList.count - 5 && self.hasMoreModpacks && !self.isLoadingModpacks) {
        [self loadModpackList];
    }

    if (tableView == self.resourcepackTableView && indexPath.row == self.resourcepackList.count - 5 && self.hasMoreResourcepacks && !self.isLoadingResourcepacks) {
        [self loadResourcePackList];
    }

    if (tableView == self.datapackTableView && indexPath.row == self.datapackList.count - 5 && self.hasMoreDatapacks && !self.isLoadingDatapacks) {
        [self loadDataPackList];
    }

    if (tableView == self.worldTableView && indexPath.row == self.worldList.count - 5 && self.hasMoreWorlds && !self.isLoadingWorlds) {
        [self loadWorldList];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (tableView == self.modTableView) {
        if (indexPath.row == self.modList.count && self.hasMoreMods) {
            [self loadModList];
            return;
        }
        [self downloadModAtIndexPath:indexPath];
    } else if (tableView == self.shaderTableView) {
        if (indexPath.row == self.shaderList.count && self.hasMoreShaders) {
            [self loadShaderList];
            return;
        }
        [self downloadShaderAtIndexPath:indexPath];
    } else if (tableView == self.resourcepackTableView) {
        if (indexPath.row == self.resourcepackList.count && self.hasMoreResourcepacks) {
            [self loadResourcePackList];
            return;
        }
        [self downloadResourcepackAtIndexPath:indexPath];
    } else if (tableView == self.datapackTableView) {
        if (indexPath.row == self.datapackList.count && self.hasMoreDatapacks) {
            [self loadDataPackList];
            return;
        }
        [self downloadDatapackAtIndexPath:indexPath];
    } else if (tableView == self.worldTableView) {
        if (indexPath.row == self.worldList.count && self.hasMoreWorlds) {
            [self loadWorldList];
            return;
        }
        [self downloadWorldAtIndexPath:indexPath];
    } else if (tableView == self.modpackTableView) {
        if (indexPath.row == self.modpackList.count && self.hasMoreModpacks) {
            [self loadModpackList];
            return;
        }
        [self installModpackAtIndexPath:indexPath];
    }
}

#pragma mark - Download Actions

- (void)downloadMod:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadModAtIndexPath:indexPath];
}

- (void)downloadModAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.modList.count) return;

    NSDictionary *mod = self.modList[indexPath.row];
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:mod];

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;

    // 在中间内容区 push 显示，而非弹窗盖在下载列表之上（与 FCL 安卓一致）
    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadShader:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadShaderAtIndexPath:indexPath];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;

    NSDictionary *shader = self.shaderList[indexPath.row];
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:shader];

    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;
    versionVC.title = shaderItem.displayName;

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadResourcepack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadResourcepackAtIndexPath:indexPath];
}

- (void)downloadResourcepackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.resourcepackList.count) return;

    NSDictionary *resourcepack = self.resourcepackList[indexPath.row];
    ResourcePackItem *item = [[ResourcePackItem alloc] initWithOnlineData:resourcepack];

    self.pendingDownloadType = @"resourcepack";
    self.pendingResourcePackItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeResourcePack;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // 传入项目展示信息（用于详情 header 显示封面图/作者/下载量/标签/描述）
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.resourcePackDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadDatapack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadDatapackAtIndexPath:indexPath];
}

- (void)downloadDatapackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.datapackList.count) return;

    NSDictionary *datapack = self.datapackList[indexPath.row];
    DataPackItem *item = [[DataPackItem alloc] initWithOnlineData:datapack];

    self.pendingDownloadType = @"datapack";
    self.pendingDataPackItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeDataPack;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // 传入项目展示信息（用于详情 header 显示封面图/作者/下载量/标签/描述）
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.dataPackDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadWorld:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadWorldAtIndexPath:indexPath];
}

- (void)downloadWorldAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.worldList.count) return;

    NSDictionary *world = self.worldList[indexPath.row];
    WorldItem *item = [[WorldItem alloc] initWithOnlineData:world];

    self.pendingDownloadType = @"world";
    self.pendingWorldItem = item;

    AssetVersionViewController *versionVC = [[AssetVersionViewController alloc] init];
    versionVC.assetType = AssetVersionTypeWorld;
    versionVC.projectID = item.onlineID;
    versionVC.projectDisplayName = item.displayName;
    versionVC.delegate = self;
    versionVC.title = item.displayName;
    // 传入项目展示信息（用于详情 header 显示封面图/作者/下载量/标签/描述）
    versionVC.projectIconURL = item.iconURL;
    versionVC.projectAuthor = item.author;
    versionVC.projectDownloads = item.downloads;
    versionVC.projectLikes = item.likes;
    versionVC.projectDescription = item.worldDescription;
    versionVC.projectCategories = item.categories;
    versionVC.projectLastUpdated = item.lastUpdated;

    [self.navigationController pushViewController:versionVC animated:YES];
}

#pragma mark - ModVersionViewControllerDelegate

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }

    // 整合包走独立安装流程（下载+解析+导入），与普通 Mod 下载不同
    if ([self.pendingDownloadType isEqualToString:@"modpack"]) {
        NSDictionary *modpack = self.pendingModpackDict;
        self.pendingDownloadType = nil;
        self.pendingModpackDict = nil;
        // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
        [self.navigationController popViewControllerAnimated:YES];
        [self startModpackInstallation:version modpack:modpack];
        return;
    }

    ModItem *itemToDownload = viewController.modItem;
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", itemToDownload.displayName];

    // 模组下载走 ModService（resourcepack/datapack/world 已改走 AssetVersionViewController）
    self.pendingDownloadType = nil;

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];
    [self startDownloadForModItem:itemToDownload];
}

#pragma mark - AssetVersionViewControllerDelegate

- (void)assetVersionViewController:(AssetVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }

    NSString *downloadType = self.pendingDownloadType;
    self.pendingDownloadType = nil;

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];

    if ([downloadType isEqualToString:@"resourcepack"]) {
        ResourcePackItem *item = self.pendingResourcePackItem;
        self.pendingResourcePackItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        item.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", item.displayName];
        [self startDownloadForResourcePackItem:item];
    } else if ([downloadType isEqualToString:@"datapack"]) {
        DataPackItem *item = self.pendingDataPackItem;
        self.pendingDataPackItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        item.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", item.displayName];
        [self startDownloadForDataPackItem:item];
    } else if ([downloadType isEqualToString:@"world"]) {
        WorldItem *item = self.pendingWorldItem;
        self.pendingWorldItem = nil;
        if (!item) return;
        item.selectedVersionDownloadURL = primaryFile[@"url"];
        [self startDownloadForWorldItem:item];
    }
}

- (void)startDownloadForModItem:(ModItem *)item {
    // FCL 风格：push 进度页（不确定模式），替代 alert 转圈
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在下载 %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在下载模组文件...";
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";

    __weak typeof(self) weakSelf = self;
    [[ModService sharedService] downloadMod:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (error) {
                [strongSelf showError:error.localizedDescription];
            } else {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 已安装", item.displayName]];
            }
        });
    }];
}

// 下载资源包（使用 ResourcePackService，NSString profileName）
- (void)startDownloadForResourcePackItem:(ResourcePackItem *)item {
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在下载 %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在下载资源包...";
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    __weak InstallerProgressViewController *weakProgressVC = progressVC;
    [[ResourcePackService sharedService] downloadResourcePack:item
                                                    toProfile:profileName
                                                     progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (downloadProgress && weakProgressVC) {
                weakProgressVC.progress = downloadProgress.fractionCompleted;
            }
        });
    } completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 已安装到 resourcepacks", item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: @"资源包下载失败"];
            }
        });
    }];
}

// 下载数据包（使用 DataPackService，NSString profileName）
- (void)startDownloadForDataPackItem:(DataPackItem *)item {
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在下载 %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在下载数据包...";
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    __weak InstallerProgressViewController *weakProgressVC = progressVC;
    [[DataPackService sharedService] downloadDataPack:item
                                            toProfile:profileName
                                             progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (downloadProgress && weakProgressVC) {
                weakProgressVC.progress = downloadProgress.fractionCompleted;
            }
        });
    } completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 已安装到 datapacks\n请手动移动到对应世界目录", item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: @"数据包下载失败"];
            }
        });
    }];
}

// 下载世界存档并解压到 saves 目录（使用 WorldService，含进度回调与健壮解压）
- (void)startDownloadForWorldItem:(WorldItem *)item {
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在下载 %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在下载世界存档...";
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    __weak InstallerProgressViewController *weakProgressVC = progressVC;
    [[WorldService sharedService] downloadWorld:item
                                        toProfile:profileName
                                         progress:^(NSProgress * _Nullable downloadProgress) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (downloadProgress && weakProgressVC) {
                weakProgressVC.progress = downloadProgress.fractionCompleted;
            }
        });
    } completion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (success && !error) {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 已解压到 saves 目录", item.displayName]];
            } else {
                [strongSelf showError:error.localizedDescription ?: @"世界下载失败"];
            }
        });
    }];
}

#pragma mark - ShaderVersionViewControllerDelegate

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    ShaderItem *itemToDownload = viewController.shaderItem;
    
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }
    
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.zip", itemToDownload.displayName];

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];
    [self startDownloadForShaderItem:itemToDownload];
}

- (void)startDownloadForShaderItem:(ShaderItem *)item {
    // FCL 风格：push 进度页（不确定模式），替代 alert 转圈
    InstallerProgressViewController *progressVC = [[InstallerProgressViewController alloc] init];
    progressVC.titleText = [NSString stringWithFormat:@"正在下载 %@", item.displayName ?: @""];
    progressVC.progress = -1;
    progressVC.stageMessage = @"正在下载光影包...";
    [self.navigationController pushViewController:progressVC animated:YES];

    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";

    __weak typeof(self) weakSelf = self;
    [[ShaderService sharedService] downloadShader:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.navigationController popViewControllerAnimated:YES];
            if (error) {
                [strongSelf showError:error.localizedDescription];
            } else {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 已安装", item.displayName]];
            }
        });
    }];
}

#pragma mark - Network & Progress

- (BOOL)isNetworkAvailable {
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
    if (!reachability) return NO;
    
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    
    return success && (flags & kSCNetworkReachabilityFlagsReachable) && !(flags & kSCNetworkReachabilityFlagsConnectionRequired);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // 原版前置安装进度（独立 context，避免与主下载流程冲突）
    if ([(__bridge NSString *)context isEqualToString:@"VanillaPreinstallContext"]) {
        [self handleVanillaPreinstallProgress];
        return;
    }
    if (![(__bridge NSString *)context isEqualToString:@"DownloadProgressContext"]) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    NSProgress *progress = self.downloadTask.progress;
    NSProgress *textProgress = self.downloadTask.textProgress;
    if (!textProgress) return;
    
    NSInteger completedUnitCount = progress.totalUnitCount * progress.fractionCompleted;
    textProgress.completedUnitCount = completedUnitCount;
    
    static CGFloat lastMsTime = 0;
    static NSUInteger lastSecTime = 0;
    static NSInteger lastCompletedUnitCount = 0;
    
    struct timeval tv;
    gettimeofday(&tv, NULL);
    
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        if (lastMsTime > 0) {
            NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
            textProgress.throughput = @(throughput);
            if (throughput > 0) {
                NSInteger remaining = (progress.totalUnitCount - completedUnitCount) / throughput;
                textProgress.estimatedTimeRemaining = @(remaining);
            }
        }
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressVC) {
            // 更新进度视图
        } else if (self.downloadingAlert) {
            NSString *progressText = textProgress.localizedAdditionalDescription;
            if (!progressText || progressText.length == 0) {
                progressText = [NSString stringWithFormat:@"%.1f%%", progress.fractionCompleted * 100];
            }
            
            NSString *speedText = @"";
            if (textProgress.throughput) {
                NSInteger speed = [textProgress.throughput integerValue];
                if (speed > 1024 * 1024) {
                    speedText = [NSString stringWithFormat:@" • %.1f MB/s", speed / (1024.0 * 1024.0)];
                } else if (speed > 1024) {
                    speedText = [NSString stringWithFormat:@" • %.1f KB/s", speed / 1024.0];
                } else if (speed > 0) {
                    speedText = [NSString stringWithFormat:@" • %ld B/s", (long)speed];
                }
            }
            
            NSString *etaText = @"";
            if (textProgress.estimatedTimeRemaining) {
                NSInteger eta = [textProgress.estimatedTimeRemaining integerValue];
                if (eta > 3600) {
                    etaText = [NSString stringWithFormat:@" • 剩余 %ld小时%ld分", (long)(eta / 3600), (long)((eta % 3600) / 60)];
                } else if (eta > 60) {
                    etaText = [NSString stringWithFormat:@" • 剩余 %ld分%ld秒", (long)(eta / 60), (long)(eta % 60)];
                } else if (eta > 0) {
                    etaText = [NSString stringWithFormat:@" • 剩余 %ld秒", (long)eta];
                }
            }
            
            [self.downloadingAlert updateMessage:[NSString stringWithFormat:@"正在下载...\n%@%@%@", progressText, speedText, etaText]];
        }

        if (progress.finished) {
            if (self.isObservingProgress) {
                [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
                self.isObservingProgress = NO;
            }

            lastMsTime = 0;
            lastSecTime = 0;
            lastCompletedUnitCount = 0;

            self.view.userInteractionEnabled = YES;
            [self.loadingIndicator stopAnimating];

            if (self.downloadingAlert) {
                [self.downloadingAlert dismiss];
                self.downloadingAlert = nil;
            }
            
            if (self.progressVC) {
                [self.progressVC dismissViewControllerAnimated:YES completion:nil];
                self.progressVC = nil;
            }
            
            // 在内容区显示下载完成提示，替代弹窗
            [InlineMessageView showInViewController:self
                                               title:@"下载完成"
                                            message:[NSString stringWithFormat:@"%@ 下载完成", self.downloadTask.metadata[@"id"] ?: @"版本"]
                                               type:InlineMessageTypeSuccess];
            
            self.downloadTask = nil;
        }
    });
}

/// 原版前置安装的进度处理：更新 FCL 风格进度 VC，完成时弹出 VC 并触发后续模组加载器安装。
- (void)handleVanillaPreinstallProgress {
    MinecraftResourceDownloadTask *task = self.vanillaPreinstallTask;
    if (!task) return;
    NSProgress *progress = task.progress;
    NSProgress *textProgress = task.textProgress;
    double fraction = progress.fractionCompleted;

    // 计算 speed / ETA（与主下载流程一致）
    static CGFloat lastMsTime = 0;
    static NSUInteger lastSecTime = 0;
    static NSInteger lastCompletedUnitCount = 0;
    if (textProgress) {
        NSInteger completedUnitCount = progress.totalUnitCount * fraction;
        textProgress.completedUnitCount = completedUnitCount;
        struct timeval tv;
        gettimeofday(&tv, NULL);
        if (lastSecTime < tv.tv_sec) {
            CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
            if (lastMsTime > 0) {
                NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
                textProgress.throughput = @(throughput);
                if (throughput > 0) {
                    NSInteger remaining = (progress.totalUnitCount - completedUnitCount) / throughput;
                    textProgress.estimatedTimeRemaining = @(remaining);
                }
            }
            lastCompletedUnitCount = completedUnitCount;
            lastSecTime = tv.tv_sec;
            lastMsTime = currentTime;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(self) s = self;
        if (!s) return;
        InstallerProgressViewController *pvc = s.vanillaPreinstallProgressVC;
        if (pvc) {
            if (fraction >= 0.0 && progress.totalUnitCount > 1) {
                pvc.progress = fraction;
            } else {
                pvc.progress = -1; // 不确定模式
            }
            // 阶段文案：百分比 + 速度 + 剩余时间
            NSString *stage = [NSString stringWithFormat:@"%.1f%%", fraction * 100.0];
            if (textProgress.throughput) {
                NSInteger speed = [textProgress.throughput integerValue];
                if (speed > 1024 * 1024) {
                    stage = [stage stringByAppendingFormat:@" • %.1f MB/s", speed / (1024.0 * 1024.0)];
                } else if (speed > 1024) {
                    stage = [stage stringByAppendingFormat:@" • %.1f KB/s", speed / 1024.0];
                } else if (speed > 0) {
                    stage = [stage stringByAppendingFormat:@" • %ld B/s", (long)speed];
                }
            }
            if (textProgress.estimatedTimeRemaining) {
                NSInteger eta = [textProgress.estimatedTimeRemaining integerValue];
                if (eta > 60) {
                    stage = [stage stringByAppendingFormat:@" • 剩余 %ld分%ld秒", (long)(eta / 60), (long)(eta % 60)];
                } else if (eta > 0) {
                    stage = [stage stringByAppendingFormat:@" • 剩余 %ld秒", (long)eta];
                }
            }
            pvc.stageMessage = stage;
        }

        if (progress.finished) {
            // 重置速度统计静态变量
            lastMsTime = 0;
            lastSecTime = 0;
            lastCompletedUnitCount = 0;

            if (s.isObservingVanillaPreinstall) {
                [s.vanillaPreinstallTask.progress removeObserver:s forKeyPath:@"fractionCompleted"];
                s.isObservingVanillaPreinstall = NO;
            }
            if (s.vanillaPreinstallProgressVC && [s.navigationController.viewControllers containsObject:s.vanillaPreinstallProgressVC]) {
                [s.navigationController popViewControllerAnimated:YES];
            }
            s.vanillaPreinstallTask = nil;
            s.vanillaPreinstallProgressVC = nil;
            void (^cb)(BOOL) = s.vanillaPreinstallCompletion;
            s.vanillaPreinstallCompletion = nil;
            if (cb) cb(YES);
        }
    });
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - Helper Methods

- (NSString *)currentInstanceModsPath {
    // 参考 ModService.m 的 existingModsFolderForProfile: 逻辑：
    // 1. 优先读取 profile 的 gameDir，拼接 /mods
    // 2. 若 profile 无 gameDir 或 gameDir 为 "."，回退到 $POJAV_GAME_DIR/mods
    NSString *instanceName = PLProfiles.current.selectedProfileName;
    if (!instanceName) instanceName = @"default";

    NSString *modsDir = nil;

    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[instanceName];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
                // gameDir 是相对路径时，相对于 POJAV_GAME_DIR 解析
                NSString *baseDir;
                const char *env = getenv("POJAV_GAME_DIR");
                if (env) {
                    baseDir = [NSString stringWithUTF8String:env];
                } else {
                    baseDir = NSHomeDirectory();
                }

                if ([gameDir isAbsolutePath]) {
                    modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
                } else {
                    modsDir = [[baseDir stringByAppendingPathComponent:gameDir] stringByAppendingPathComponent:@"mods"];
                }
            }
        }
    } @catch (NSException *ex) { }

    if (!modsDir) {
        // 回退到 $POJAV_GAME_DIR/mods（与 FCL 默认行为一致）
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    }

    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.versionCollectionView reloadData];
    });
}

@end