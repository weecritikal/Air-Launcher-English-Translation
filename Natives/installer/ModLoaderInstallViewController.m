//
//  ModLoaderInstallViewController.m
//  Amethyst
//
//  参照 FCL (FoldCraftLauncher) 的模组加载器选择界面重构。
//  视觉风格与 VersionManagerViewController 的"原版安装列表"完全一致：
//  使用 UICollectionView + CompositionalLayout + 卡片式 cell（毛玻璃 + 阴影 + 圆角）。
//
//  主要改进：
//  1. 加载器列表用 UICollectionView 卡片式布局（与 VersionManagerViewController
//     的 VMTileBaseCell / VMVersionCardCell / VMSectionHeaderView 风格一致），
//     全宽卡片 86pt 高度，左侧加载器图标 36pt + 中间名称/描述 + 右侧状态/选中徽章。
//  2. 互斥逻辑与 FCL 完全一致：
//     - forge/fabric/quilt/neoforge 互斥
//     - optifine 与 fabric/quilt/neoforge 不兼容（与 forge 可共存）
//     - fabricApi 依赖 fabric，与 forge/optifine/neoforge 互斥
//  3. 版本列表 push 到独立的 ModLoaderVersionPickerViewController，
//     解决原实现"加载器列表固定 320pt + optionsContainer 50pt + 安装按钮"
//     在 iPhone 上挤压 versionTableView 到接近 0 高度的问题。
//     子页面 cell 也改为卡片式（ModLoaderVersionCardCell）。
//  4. 底部安装按钮钉在 safeAreaLayoutGuide.bottomAnchor，iPhone 上不会被 Home Indicator 遮挡。
//  5. 顶部新增"版本名"输入框，自动生成 "游戏版本-加载器名"（参照 FCL VersionInstallInfoPage）。
//  6. 文字颜色统一白色（BackgroundManager 使用 SystemMaterialDark 深色样式）。
//

#import "ModLoaderInstallViewController.h"
#import "NeoForgeVersionFetcher.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "ModLoaderIconHelper.h"
#import "ScreenUtils.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Data Models

/// 加载器元数据
@interface ModLoaderRow : NSObject
@property (nonatomic, copy) NSString *identifier;   // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *name;         // 显示名
@property (nonatomic, copy) NSString *desc;         // 描述
@property (nonatomic, copy) NSString *iconName;     // SF Symbol 名（PNG 缺失时回退用）
@property (nonatomic, strong) UIColor *iconColor;   // 图标主色
@property (nonatomic, assign) BOOL compatible;      // 与当前游戏版本是否兼容
@property (nonatomic, copy, nullable) NSString *selectedVersion; // 选中版本（nil 表示未选）
@end
@implementation ModLoaderRow
@end

#pragma mark - Card Base Cell (参照 VMTileBaseCell)

@interface ModLoaderCardBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
- (void)setupViews;
@end

@implementation ModLoaderCardBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 阴影：cell 层级，masksToBounds = NO 才能让阴影外溢
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.layer.shadowOpacity = 0.15;
    self.layer.shadowRadius = 8;
    self.layer.masksToBounds = NO;

    // contentContainer：圆角 + 裁切，承载毛玻璃和子视图
    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentContainer.layer.cornerRadius = 12;
    self.contentContainer.layer.masksToBounds = YES;
    [self.contentView addSubview:self.contentContainer];

    // BackgroundManager 的 applyEffectToCollectionViewCell: 会在 cell 上叠加毛玻璃
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

#pragma mark - Loader Card Cell (参照 VMVersionCardCell)

@interface ModLoaderCardCell : ModLoaderCardBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *statusLabel;       // 右侧状态：选中版本/不兼容/未选择
@property (nonatomic, strong) UIView *selectedBadge;      // 选中时显示的绿色圆圈 + 勾选
@property (nonatomic, strong) UIImageView *chevronView;   // 不兼容时隐藏，提示可点击
@end

@implementation ModLoaderCardCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:36];
    CGFloat nameFont = [ScreenUtils sp:16];
    CGFloat descFont = [ScreenUtils sp:12];
    CGFloat statusFont = [ScreenUtils sp:13];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    // BackgroundManager 的毛玻璃使用 SystemMaterialDark 深色样式，文字必须用白色
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.descLabel = [[UILabel alloc] init];
    self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descLabel.font = [UIFont systemFontOfSize:descFont weight:UIFontWeightRegular];
    self.descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    self.descLabel.numberOfLines = 2;
    self.descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.descLabel];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:statusFont weight:UIFontWeightRegular];
    self.statusLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    self.statusLabel.textAlignment = NSTextAlignmentRight;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.statusLabel];

    self.chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chevronView.tintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
    self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.chevronView];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = [UIColor systemGreenColor];
    self.selectedBadge.layer.cornerRadius = 12;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],

        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.statusLabel.leadingAnchor constant:-8],

        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:4],
        [self.descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.statusLabel.leadingAnchor constant:-8],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-12],

        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-4],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:140],

        [self.chevronView.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.chevronView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.chevronView.widthAnchor constraintEqualToConstant:14],
        [self.chevronView.heightAnchor constraintEqualToConstant:14],

        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.nameLabel.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:24],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:24],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],
    ]];
}

- (void)setIncompatible:(BOOL)incompatible reason:(NSString *)reason {
    if (incompatible) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = reason ?: @"不兼容";
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.nameLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
        self.descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35];
        self.iconView.alpha = 0.5;
        self.chevronView.hidden = YES;
        self.selectedBadge.hidden = YES;
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06].CGColor;
        self.contentView.layer.borderWidth = 0.5;
        self.contentView.userInteractionEnabled = NO;
    } else {
        self.nameLabel.textColor = [UIColor whiteColor];
        self.descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
        self.iconView.alpha = 1.0;
        self.chevronView.hidden = NO;
        self.contentView.userInteractionEnabled = YES;
    }
}

- (void)setSelectedVersionText:(NSString *)text {
    if (text.length > 0) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = text;
        self.statusLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"选择版本";
        self.statusLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    }
}

/// 清空右侧状态文字（未选中加载器时使用）
- (void)clearStatusText {
    self.statusLabel.hidden = YES;
    self.statusLabel.text = nil;
}

- (void)configureWithRow:(ModLoaderRow *)row
            isSelected:(BOOL)isSelected
      selectedVersionDisplay:(NSString *)versionDisplay
                incompatible:(BOOL)incompatible
                     reason:(NSString *)reason {
    self.nameLabel.text = row.name;
    self.descLabel.text = row.desc;

    // 通过 ModLoaderIconHelper 统一配置加载器图标（优先 PNG，回退 SF Symbol + 品牌色）
    [ModLoaderIconHelper configureImageView:self.iconView
                                  forLoader:row.identifier
                             traitCollection:self.traitCollection];

    if (incompatible) {
        [self setIncompatible:YES reason:reason];
        return;
    }

    [self setIncompatible:NO reason:nil];

    if (isSelected) {
        if (versionDisplay.length > 0) {
            [self setSelectedVersionText:versionDisplay];
        } else if ([row.identifier isEqualToString:@"vanilla"]) {
            [self setSelectedVersionText:@"已选择"];
        } else {
            [self setSelectedVersionText:nil];
        }
        self.selectedBadge.hidden = NO;
        self.contentView.layer.borderColor = [UIColor systemGreenColor].CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else {
        [self clearStatusText];
        self.selectedBadge.hidden = YES;
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
}

@end

#pragma mark - Switch Card Cell (Fabric API / OptiFine 选项卡片)

@interface ModLoaderSwitchCardCell : ModLoaderCardBaseCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UISwitch *switchControl;
@end

@implementation ModLoaderSwitchCardCell

- (void)setupViews {
    [super setupViews];

    CGFloat titleFont = [ScreenUtils sp:16];
    CGFloat descFont = [ScreenUtils sp:12];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:titleFont weight:UIFontWeightSemibold];
    // 毛玻璃使用深色样式，文字必须用白色
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.titleLabel];

    self.descLabel = [[UILabel alloc] init];
    self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descLabel.font = [UIFont systemFontOfSize:descFont weight:UIFontWeightRegular];
    self.descLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.65];
    self.descLabel.numberOfLines = 0;
    self.descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.descLabel];

    self.switchControl = [[UISwitch alloc] init];
    self.switchControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.switchControl];

    // 默认边框：与版本卡片保持一致的弱边框
    self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    self.contentView.layer.borderWidth = 0.5;

    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],

        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.switchControl.leadingAnchor constant:-12],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-12],

        [self.switchControl.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.switchControl.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
    ]];
}

@end

#pragma mark - Section Header View (参照 VMSectionHeaderView)

@interface ModLoaderSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation ModLoaderSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Section header 需要深色背景托底，避免在透明 collectionView 上文字透到父背景。
        // 与 BackgroundManager 的深色风格保持一致。
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:blurView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:18] weight:UIFontWeightBold];
        self.titleLabel.textColor = [UIColor whiteColor];
        self.titleLabel.adjustsFontForContentSizeCategory = NO;
        [self addSubview:self.titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [blurView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [blurView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [blurView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [blurView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}

@end

#pragma mark - Version Picker Card Cell (版本选择子页面的卡片)

@interface ModLoaderVersionCardCell : ModLoaderCardBaseCell
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderVersionCardCell

- (void)setupViews {
    [super setupViews];

    CGFloat versionFont = [ScreenUtils sp:15];

    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:versionFont weight:UIFontWeightMedium];
    // 毛玻璃深色样式：文字必须用白色
    self.versionLabel.textColor = [UIColor whiteColor];
    self.versionLabel.numberOfLines = 1;
    self.versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.versionLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = [UIColor systemGreenColor];
    self.selectedBadge.layer.cornerRadius = 12;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:10 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    // 默认弱边框
    self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
    self.contentView.layer.borderWidth = 0.5;

    [NSLayoutConstraint activateConstraints:@[
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.versionLabel.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],

        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:24],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:24],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor],
    ]];
}

- (void)configureWithDisplay:(NSString *)display isSelected:(BOOL)isSelected {
    self.versionLabel.text = display;
    self.selectedBadge.hidden = !isSelected;
    if (isSelected) {
        self.contentView.layer.borderColor = [UIColor systemGreenColor].CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else {
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
}

@end

#pragma mark - Version Picker View Controller (版本选择子页面)

@interface ModLoaderVersionPickerViewController : UIViewController <UICollectionViewDataSource, UICollectionViewDelegate, NSXMLParserDelegate>
@property (nonatomic, copy) NSString *loaderId;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy) NSString *selectedVersion;
@property (nonatomic, copy) void (^onSelected)(NSString *version);
@property (nonatomic, copy) void (^onCancelled)(void);
@end

@interface ModLoaderVersionPickerViewController ()
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) NSArray *versions;
// Forge XML 解析
@property (nonatomic, strong) NSMutableArray *forgeVersionList;
@property (nonatomic, strong) NSMutableString *currentVersionValue;
@property (nonatomic, assign) BOOL isParsingForge;
// 网络任务
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSessionDataTask *bmclTask;
@end

@implementation ModLoaderVersionPickerViewController

- (void)dealloc {
    if (_currentTask) { [_currentTask cancel]; _currentTask = nil; }
    if (_bmclTask) { [_bmclTask cancel]; _bmclTask = nil; }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    self.view.backgroundColor = [UIColor clearColor];
    // 适配自定义启动器背景（参照 ForgeInstallViewController / VersionManagerViewController）
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor whiteColor];

    [self setupCollectionView];
    [self startLoading];
}

- (void)refreshBackgroundEffect {
    // 背景效果切换时刷新 cell 毛玻璃外观
    [_collectionView reloadData];
}

- (NSString *)pickerTitle {
    if ([_loaderId isEqualToString:@"fabric"])   return @"Fabric 版本";
    if ([_loaderId isEqualToString:@"forge"])    return @"Forge 版本";
    if ([_loaderId isEqualToString:@"neoforge"]) return @"NeoForge 版本";
    if ([_loaderId isEqualToString:@"quilt"])    return @"Quilt 版本";
    if ([_loaderId isEqualToString:@"optifine"]) return @"OptiFine 版本";
    return @"选择版本";
}

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    _collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    _collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.alwaysBounceVertical = YES;
    // 与 VersionManagerViewController 一致：避免系统叠加 safeArea.top，
    // 手动用 contentInset.top = nav bar 高度让首行从 nav bar 下方开始绘制
    _collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    CGFloat navBarHeight = 44.0;
    if (self.navigationController && self.navigationController.navigationBar.bounds.size.height > 0) {
        navBarHeight = self.navigationController.navigationBar.bounds.size.height;
    }
    _collectionView.contentInset = UIEdgeInsetsMake(navBarHeight, 0, 0, 0);
    _collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(navBarHeight, 0, 0, 0);

    [_collectionView registerClass:[ModLoaderVersionCardCell class] forCellWithReuseIdentifier:@"VersionCardCell"];
    [self.view addSubview:_collectionView];

    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.text = @"暂无可用版本";
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor whiteColor];
    _emptyLabel.font = [UIFont systemFontOfSize:15];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.text = @"加载失败，请检查网络";
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.textColor = [UIColor systemRedColor];
    _errorLabel.font = [UIFont systemFontOfSize:15];
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [_loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [_errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [_errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        // 全宽卡片，高度 60pt（版本行内容较少，比加载器卡片矮）
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:60]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
        item.contentInsets = NSDirectionalEdgeInsetsMake(4, 14, 4, 14);

        NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                  heightDimension:[NSCollectionLayoutDimension absoluteDimension:60]];
        NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
        section.contentInsets = NSDirectionalEdgeInsetsMake(8, 0, 20, 0);
        return section;
    }];
}

- (void)backTapped {
    if (_onCancelled) _onCancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)startLoading {
    _versions = nil;
    [_collectionView reloadData];
    _emptyLabel.hidden = YES;
    _errorLabel.hidden = YES;
    [_loadingIndicator startAnimating];

    if ([_loaderId isEqualToString:@"fabric"] || [_loaderId isEqualToString:@"quilt"]) {
        [self loadFabricLikeVersions:_loaderId];
    } else if ([_loaderId isEqualToString:@"forge"]) {
        [self loadForgeVersions];
    } else if ([_loaderId isEqualToString:@"neoforge"]) {
        [self loadNeoForgeVersions];
    } else if ([_loaderId isEqualToString:@"optifine"]) {
        [self loadOptiFineVersions];
    } else {
        [self finishLoadingWithVersions:@[] error:nil];
    }
}

#pragma mark Fabric / Quilt

- (void)loadFabricLikeVersions:(NSString *)loaderType {
    NSString *metaBase = [loaderType isEqualToString:@"quilt"]
        ? @"https://meta.quiltmc.org/v3/versions/loader"
        : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", metaBase, _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!versions || jsonError) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *ver in versions) {
                if (![ver isKindOfClass:[NSDictionary class]]) continue;
                NSString *loaderVersion = ver[@"loader"][@"version"];
                if (loaderVersion && ![list containsObject:loaderVersion]) {
                    [list addObject:loaderVersion];
                }
            }
            [strongSelf finishLoadingWithVersions:list error:nil];
        });
    }];
    [_currentTask resume];
}

#pragma mark Forge (并发竞速，参照原 loadForgeVersionsReal)

- (void)loadForgeVersions {
    // 参照 FCL/HMCL：并发竞速同时发起官方源和 BMCL API 请求，谁先成功用谁
    NSString *bmclURL = @"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/maven-metadata.xml";
    NSString *officialURL = @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml";

    _forgeVersionList = [NSMutableArray array];
    _isParsingForge = YES;

    __weak typeof(self) weakSelf = self;
    __block BOOL settled = NO;

    NSString *userAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

    void (^processData)(NSData *) = ^(NSData *data) {
        @synchronized(weakSelf) {
            if (settled) return;
            settled = YES;
        }
        if (!data || data.length == 0) return;
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        parser.delegate = weakSelf;
        [parser parse];
    };

    NSMutableURLRequest *bmclRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:bmclURL]];
    bmclRequest.timeoutInterval = 20.0;
    [bmclRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _bmclTask = [[NSURLSession sharedSession] dataTaskWithRequest:bmclRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            @synchronized(weakSelf) { if (settled) return; }
            return;
        }
        processData(data);
    }];

    NSMutableURLRequest *officialRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:officialURL]];
    officialRequest.timeoutInterval = 20.0;
    [officialRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _currentTask = [[NSURLSession sharedSession] dataTaskWithRequest:officialRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            @synchronized(weakSelf) { if (settled) return; }
            // 给 BMCLAPI 5s 宽限期
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @synchronized(weakSelf) {
                    if (settled) return;
                    settled = YES;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (!strongSelf) return;
                    [strongSelf finishLoadingWithVersions:@[] error:error];
                });
            });
            return;
        }
        processData(data);
    }];

    [_bmclTask resume];
    [_currentTask resume];
}

#pragma mark NeoForge

- (void)loadNeoForgeVersions {
    __weak typeof(self) weakSelf = self;
    [NeoForgeVersionFetcher fetchVersionsForGameVersion:_gameVersion completion:^(NSArray *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf finishLoadingWithVersions:versions ?: @[] error:error];
        });
    }];
}

#pragma mark OptiFine (BMCLAPI 列表)

- (void)loadOptiFineVersions {
    NSString *urlString = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *list = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!list || jsonError || ![list isKindOfClass:[NSArray class]]) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *versions = [NSMutableArray array];
            for (NSDictionary *item in list) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = item[@"type"] ?: @"";
                NSString *patch = item[@"patch"] ?: @"";
                NSString *filename = item[@"filename"] ?: @"";
                if (patch.length == 0) continue;
                // 显示格式：HD_U_I6 (filename)
                NSString *display = [NSString stringWithFormat:@"%@_%@", type, patch];
                if (filename.length > 0) {
                    display = [NSString stringWithFormat:@"%@_%@ (%@)", type, patch, filename];
                }
                // 把完整信息打包进 version 字符串，用 \x1f 分隔（unit separator）
                NSString *packed = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@", type, patch, filename, display];
                [versions addObject:packed];
            }
            [strongSelf finishLoadingWithVersions:versions error:nil];
        });
    }];
    [_currentTask resume];
}

- (void)finishLoadingWithVersions:(NSArray *)versions error:(NSError *)error {
    [_loadingIndicator stopAnimating];
    _isParsingForge = NO;

    if (error && versions.count == 0) {
        _versions = @[];
        _errorLabel.hidden = NO;
        _emptyLabel.hidden = YES;
        _errorLabel.text = [NSString stringWithFormat:@"加载失败：%@", error.localizedDescription ?: @"未知错误"];
    } else {
        _versions = versions ?: @[];
        _errorLabel.hidden = YES;
        _emptyLabel.hidden = (_versions.count > 0);
    }
    [_collectionView reloadData];

    // 若当前已选中版本，滚动到选中行
    if (_selectedVersion.length > 0 && _versions.count > 0) {
        NSUInteger idx = [_versions indexOfObject:_selectedVersion];
        if (idx != NSNotFound) {
            [self.collectionView scrollToItemAtIndexPath:[NSIndexPath indexPathForItem:idx inSection:0]
                                        atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
        }
    }
}

#pragma mark NSXMLParserDelegate (Forge)

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"version"]) {
        _currentVersionValue = [NSMutableString new];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_currentVersionValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (!_isParsingForge) return;
    if ([elementName isEqualToString:@"version"]) {
        NSString *version = [_currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (version.length > 0) {
            @synchronized (self) {
                NSString *prefix = [self.gameVersion stringByAppendingString:@"-"];
                if ([version hasPrefix:prefix]) {
                    [self.forgeVersionList addObject:version];
                }
            }
        }
    }
}

- (void)parserDidEndDocument:(NSXMLParser *)parser {
    _isParsingForge = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.forgeVersionList sortUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
            return [v2 compare:v1 options:NSNumericSearch];
        }];
        [self finishLoadingWithVersions:self.forgeVersionList error:nil];
    });
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    _isParsingForge = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finishLoadingWithVersions:@[] error:parseError];
    });
}

#pragma mark CollectionView

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return _versions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ModLoaderVersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCardCell" forIndexPath:indexPath];
    NSString *raw = _versions[indexPath.row];

    // 处理 OptiFine packed 格式（type\x1fpatch\x1ffilename\x1fdisplay）
    NSString *display = raw;
    if ([raw containsString:@"\x1f"]) {
        NSArray *parts = [raw componentsSeparatedByString:@"\x1f"];
        if (parts.count >= 4) display = parts[3];
    }

    BOOL isSelected = [_selectedVersion isEqualToString:raw];
    [cell configureWithDisplay:display isSelected:isSelected];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    NSString *raw = _versions[indexPath.item];
    _selectedVersion = raw;
    [collectionView reloadData];

    // 短暂展示选中状态后 pop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.onSelected) self.onSelected(raw);
        if (self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

@end

#pragma mark - Main Controller

@interface ModLoaderInstallViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) UITextField *versionNameField;
@property (nonatomic, strong) UIView *nameBar;

// 数据
@property (nonatomic, strong) NSMutableArray<ModLoaderRow *> *loaders;
@property (nonatomic, copy) NSString *selectedLoaderId;       // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *selectedFabricVersion;
@property (nonatomic, copy) NSString *selectedForgeVersion;
@property (nonatomic, copy) NSString *selectedNeoForgeVersion;
@property (nonatomic, copy) NSString *selectedQuiltVersion;
@property (nonatomic, copy) NSString *selectedOptiFineVersion;
@property (nonatomic, copy) NSString *selectedOptiFineType;     // HD_U 等
@property (nonatomic, copy) NSString *selectedOptiFinePatch;
@property (nonatomic, copy) NSString *selectedOptiFineFilename;

// 选项
@property (nonatomic, assign) BOOL installFabricAPI;
@property (nonatomic, assign) BOOL installOptiFine;  // 仅 forge 选中时显示

// 用户是否手动修改过版本名
@property (nonatomic, assign) BOOL nameManuallyModified;
@end

@implementation ModLoaderInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor clearColor];
    // 适配自定义启动器背景（参照 VersionManagerViewController）
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor whiteColor];

    _installFabricAPI = YES;  // Fabric 默认勾选 Fabric API（与 FCL 默认行为一致）

    [self setupLoaders];
    [self setupNameBar];
    [self setupBottomBar];    // 先创建底部按钮，setupCollectionView 才能引用 _bottomBar.topAnchor
    [self setupCollectionView];
    [self refreshIncompatibilities];
    [self refreshVersionName];
}

- (void)refreshBackgroundEffect {
    // 背景效果切换时刷新 cell 与 nameBar 的毛玻璃外观
    [_collectionView reloadData];
}

#pragma mark Setup

- (void)setupLoaders {
    _loaders = [NSMutableArray array];

    BOOL fabricCompatible = [self isFabricCompatible];
    BOOL quiltCompatible = [self isQuiltCompatible];
    BOOL forgeCompatible = [self isForgeCompatible];
    BOOL neoForgeCompatible = [self isNeoForgeCompatible];
    BOOL optiFineCompatible = [self isOptiFineCompatible];

    // 通过 ModLoaderIconHelper 统一获取加载器图标和品牌色（优先 PNG，回退 SF Symbol）
    NSArray *defs = @[
        @{ @"id": @"vanilla",  @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"compatible": @YES },
        @{ @"id": @"fabric",   @"name": @"Fabric",        @"desc": @"轻量级模组加载器，适合小型模组",      @"compatible": @(fabricCompatible) },
        @{ @"id": @"forge",    @"name": @"Forge",         @"desc": @"经典模组加载器，模组生态丰富",        @"compatible": @(forgeCompatible) },
        @{ @"id": @"neoforge", @"name": @"NeoForge",      @"desc": @"Forge 的分支，支持 1.20.1+",          @"compatible": @(neoForgeCompatible) },
        @{ @"id": @"quilt",    @"name": @"Quilt",         @"desc": @"基于 Fabric 的新一代加载器",         @"compatible": @(quiltCompatible) },
        @{ @"id": @"optifine", @"name": @"OptiFine",      @"desc": @"光影与画质优化（作为版本补丁安装）",  @"compatible": @(optiFineCompatible) },
    ];

    for (NSDictionary *d in defs) {
        ModLoaderRow *row = [ModLoaderRow new];
        row.identifier = d[@"id"];
        row.name = d[@"name"];
        row.desc = d[@"desc"];
        // 通过 ModLoaderIconHelper 统一获取图标符号名和品牌色（PNG 缺失时回退用）
        row.iconName = [ModLoaderIconHelper symbolNameForLoader:d[@"id"]];
        row.compatible = [d[@"compatible"] boolValue];
        row.iconColor = [ModLoaderIconHelper brandColorForLoader:d[@"id"]];
        [_loaders addObject:row];
    }
}

- (void)setupNameBar {
    _nameBar = [[UIView alloc] init];
    _nameBar.translatesAutoresizingMaskIntoConstraints = NO;
    // 适配自定义启动器背景：有全局背景时用毛玻璃，否则用默认实色
    if ([[BackgroundManager sharedManager] hasBackground]) {
        _nameBar.backgroundColor = [UIColor clearColor];
        [[BackgroundManager sharedManager] applyEffectToView:_nameBar];
        _nameBar.layer.cornerRadius = 12;
        _nameBar.layer.masksToBounds = YES;
    } else {
        _nameBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        _nameBar.layer.cornerRadius = 12;
        _nameBar.layer.masksToBounds = YES;
    }
    [self.view addSubview:_nameBar];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"版本名";
    label.font = [UIFont systemFontOfSize:[ScreenUtils sp:14] weight:UIFontWeightMedium];
    // 与卡片文字配色一致：毛玻璃深色样式下用白色
    label.textColor = [[BackgroundManager sharedManager] hasBackground] ? [UIColor whiteColor] : [UIColor secondaryLabelColor];
    label.adjustsFontForContentSizeCategory = NO;
    [_nameBar addSubview:label];

    _versionNameField = [[UITextField alloc] init];
    _versionNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _versionNameField.font = [UIFont systemFontOfSize:[ScreenUtils sp:15]];
    // 顶部 versionNameField 字色改为白色
    _versionNameField.textColor = [[BackgroundManager sharedManager] hasBackground] ? [UIColor whiteColor] : [UIColor labelColor];
    // placeholder 用浅灰色（毛玻璃下保持可读）
    _versionNameField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"输入版本名"
                                                                             attributes:@{
        NSForegroundColorAttributeName: [[BackgroundManager sharedManager] hasBackground]
            ? [[UIColor whiteColor] colorWithAlphaComponent:0.5]
            : [UIColor placeholderTextColor]
    }];
    _versionNameField.borderStyle = UITextBorderStyleNone;
    _versionNameField.returnKeyType = UIReturnKeyDone;
    _versionNameField.delegate = self;
    _versionNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _versionNameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [_nameBar addSubview:_versionNameField];

    [NSLayoutConstraint activateConstraints:@[
        [_nameBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_nameBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_nameBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_nameBar.heightAnchor constraintEqualToConstant:48],

        [label.leadingAnchor constraintEqualToAnchor:_nameBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],

        [_versionNameField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:12],
        [_versionNameField.trailingAnchor constraintEqualToAnchor:_nameBar.trailingAnchor constant:-12],
        [_versionNameField.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],
        [_versionNameField.heightAnchor constraintEqualToAnchor:_nameBar.heightAnchor],
    ]];
}

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    // 使用 Auto Layout 约束到 nameBar 和 bottomBar 之间，必须关闭 autoresizing
    _collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.alwaysBounceVertical = YES;
    // 与 VersionManagerViewController 一致：避免系统叠加 safeArea.top，
    // 这里主控制器顶部有 nameBar，不需要 navBar inset；保持 Never 让布局从 nameBar 下方开始。
    _collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _collectionView.contentInset = UIEdgeInsetsZero;
    _collectionView.scrollIndicatorInsets = UIEdgeInsetsZero;

    [_collectionView registerClass:[ModLoaderCardCell class] forCellWithReuseIdentifier:@"LoaderCardCell"];
    [_collectionView registerClass:[ModLoaderSwitchCardCell class] forCellWithReuseIdentifier:@"SwitchCardCell"];
    [_collectionView registerClass:[ModLoaderSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];
    [self.view addSubview:_collectionView];

    // 顶部约束到 nameBar 底部，底部约束到 bottomBar 顶部
    [NSLayoutConstraint activateConstraints:@[
        [_collectionView.topAnchor constraintEqualToAnchor:_nameBar.bottomAnchor constant:8],
        [_collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_collectionView.bottomAnchor constraintEqualToAnchor:_bottomBar.topAnchor],
    ]];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        // 通用 header size（参照 VersionManagerViewController：44pt 高度）
        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension absoluteDimension:44]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];

        // section 0（模组加载器）和 section 1（附加选项）都用全宽 86pt 卡片，参照 VMVersionCardCell
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:86]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
        item.contentInsets = NSDirectionalEdgeInsetsMake(4, 14, 4, 14);

        NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                  heightDimension:[NSCollectionLayoutDimension absoluteDimension:86]];
        NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
        section.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 20, 0);
        section.boundarySupplementaryItems = @[header];
        return section;
    }];
}

- (void)setupBottomBar {
    _bottomBar = [[UIView alloc] init];
    _bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    _bottomBar.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_bottomBar];

    _installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _installButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_installButton setTitle:@"安装" forState:UIControlStateNormal];
    _installButton.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:17] weight:UIFontWeightSemibold];
    _installButton.backgroundColor = [UIColor systemGreenColor];
    [_installButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _installButton.layer.cornerRadius = 10;
    [_installButton addTarget:self action:@selector(installTapped) forControlEvents:UIControlEventTouchUpInside];
    [_bottomBar addSubview:_installButton];

    [NSLayoutConstraint activateConstraints:@[
        [_bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_bottomBar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [_bottomBar.heightAnchor constraintEqualToConstant:72],

        [_installButton.leadingAnchor constraintEqualToAnchor:_bottomBar.leadingAnchor constant:16],
        [_installButton.trailingAnchor constraintEqualToAnchor:_bottomBar.trailingAnchor constant:-16],
        [_installButton.centerYAnchor constraintEqualToAnchor:_bottomBar.centerYAnchor],
        [_installButton.heightAnchor constraintEqualToConstant:50],
    ]];
}

#pragma mark Compatibility checks (与原 LoaderSelectionViewController 一致)

- (BOOL)isFabricCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 14) return YES;
    return NO;
}

- (BOOL)isQuiltCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 18) return YES;
    return NO;
}

- (BOOL)isForgeCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major == 1 && minor >= 1) return YES;
    if (major > 1) return YES;
    return NO;
}

- (BOOL)isNeoForgeCompatible {
    if (!_gameVersion) return NO;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return NO;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    NSInteger patch = (c.count > 2) ? [c[2] integerValue] : 0;
    if (major > 1) return YES;
    if (major == 1 && minor == 20 && patch >= 1) return YES;
    if (major == 1 && minor > 20) return YES;
    return NO;
}

- (BOOL)isOptiFineCompatible {
    // OptiFine 1.14+ 与 Forge 兼容，1.13 及以下独立装为版本补丁
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 8) return YES;
    return NO;
}

#pragma mark Compatibility (互斥逻辑，参照 FCL InstallerItemGroup)

- (NSString *)incompatibleReasonForLoaderId:(NSString *)loaderId {
    // fabricApi 与 forge/optifine/neoforge 互斥
    // optifine 与 fabric/quilt/neoforge 互斥（与 forge 可共存）
    // forge/fabric/quilt/neoforge 互斥

    if ([loaderId isEqualToString:@"vanilla"]) return nil;

    BOOL fabricSelected  = [_selectedLoaderId isEqualToString:@"fabric"];
    BOOL forgeSelected   = [_selectedLoaderId isEqualToString:@"forge"];
    BOOL neoSelected     = [_selectedLoaderId isEqualToString:@"neoforge"];
    BOOL quiltSelected   = [_selectedLoaderId isEqualToString:@"quilt"];
    BOOL optiSelected    = [_selectedLoaderId isEqualToString:@"optifine"];

    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"forge"] ||
        [loaderId isEqualToString:@"neoforge"] || [loaderId isEqualToString:@"quilt"]) {
        // 加载器组互斥
        if (fabricSelected  && ![loaderId isEqualToString:@"fabric"])  return @"与 Fabric 冲突";
        if (forgeSelected   && ![loaderId isEqualToString:@"forge"])   return @"与 Forge 冲突";
        if (neoSelected     && ![loaderId isEqualToString:@"neoforge"]) return @"与 NeoForge 冲突";
        if (quiltSelected   && ![loaderId isEqualToString:@"quilt"])   return @"与 Quilt 冲突";
        // optifine 与 fabric/quilt/neoforge 互斥
        if (optiSelected) {
            if ([loaderId isEqualToString:@"fabric"])  return @"与 OptiFine 冲突";
            if ([loaderId isEqualToString:@"quilt"])   return @"与 OptiFine 冲突";
            if ([loaderId isEqualToString:@"neoforge"]) return @"与 OptiFine 冲突";
        }
    }

    if ([loaderId isEqualToString:@"optifine"]) {
        if (fabricSelected)  return @"与 Fabric 冲突";
        if (quiltSelected)   return @"与 Quilt 冲突";
        if (neoSelected)     return @"与 NeoForge 冲突";
    }

    return nil;
}

- (void)refreshIncompatibilities {
    // 重新渲染所有卡片，互斥/兼容状态在 cellForItemAtIndexPath 中计算
    [_collectionView reloadData];
}

#pragma mark Version name (参照 FCL VersionInstallInfoPage.generateVersionName)

- (NSString *)generateVersionName {
    if (!_gameVersion) return @"";
    NSMutableString *name = [NSMutableString stringWithString:_gameVersion];

    // 已选加载器追加 -loaderName
    NSString *loaderId = _selectedLoaderId;
    if (loaderId.length > 0 && ![loaderId isEqualToString:@"vanilla"]) {
        NSString *loaderName = nil;
        if ([loaderId isEqualToString:@"fabric"])   loaderName = @"fabric";
        else if ([loaderId isEqualToString:@"forge"])    loaderName = @"forge";
        else if ([loaderId isEqualToString:@"neoforge"]) loaderName = @"neoforge";
        else if ([loaderId isEqualToString:@"quilt"])    loaderName = @"quilt";
        else if ([loaderId isEqualToString:@"optifine"]) loaderName = @"OptiFine";
        if (loaderName) [name appendFormat:@"-%@", loaderName];
    }

    // 若同时勾选了 OptiFine（与 Forge 共存），追加 -OptiFine
    if (_installOptiFine && [loaderId isEqualToString:@"forge"]) {
        if (![_selectedLoaderId isEqualToString:@"optifine"]) {
            [name appendString:@"-OptiFine"];
        }
    }

    return [name copy];
}

- (void)refreshVersionName {
    if (_nameManuallyModified) return;
    // 注意：变量名不能使用 "auto"，因为 auto 是 C/C++/Objective-C 的保留关键字
    // （存储类说明符），作为标识符会导致 "expected identifier or '('" 编译错误。
    // 改用 autoGeneratedName 以避免与关键字冲突。
    NSString *autoGeneratedName = [self generateVersionName];
    if (![autoGeneratedName isEqualToString:_versionNameField.text]) {
        // programmatic edit, ignore text change notification
        _versionNameField.text = autoGeneratedName;
    }
}

#pragma mark Actions

- (void)backTapped {
    if (_cancelled) _cancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)installTapped {
    if (_selectedLoaderId.length == 0) {
        [self showAlert:@"请选择安装方式" message:nil];
        return;
    }

    if (![_selectedLoaderId isEqualToString:@"vanilla"] && ![_selectedLoaderId isEqualToString:@"optifine"]) {
        NSString *selectedVersion = [self selectedVersionForLoader:_selectedLoaderId];
        if (selectedVersion.length == 0) {
            [self showAlert:@"请选择版本" message:@"请先选择加载器的版本号"];
            return;
        }
    }

    // OptiFine 单独安装时必须有选中版本
    if ([_selectedLoaderId isEqualToString:@"optifine"] && _selectedOptiFineVersion.length == 0) {
        [self showAlert:@"请选择 OptiFine 版本" message:nil];
        return;
    }

    BOOL installFabricAPI = NO;
    BOOL installOptiFine = NO;
    NSString *loaderVersion = [self selectedVersionForLoader:_selectedLoaderId];

    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        installFabricAPI = _installFabricAPI;
    } else if ([_selectedLoaderId isEqualToString:@"forge"]) {
        installOptiFine = _installOptiFine;
    } else if ([_selectedLoaderId isEqualToString:@"optifine"]) {
        // 单独安装 OptiFine：作为版本补丁
        installOptiFine = YES;
        // 单独 optifine 时 loaderVersion 为 OptiFine 完整描述（type\x1fpatch\x1ffilename\x1fdisplay）
        loaderVersion = _selectedOptiFineVersion;
    }

    if (_completion) {
        _completion(_selectedLoaderId, installFabricAPI, installOptiFine, loaderVersion);
    }
}

- (NSString *)selectedVersionForLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   return _selectedFabricVersion;
    if ([loaderId isEqualToString:@"forge"])    return _selectedForgeVersion;
    if ([loaderId isEqualToString:@"neoforge"]) return _selectedNeoForgeVersion;
    if ([loaderId isEqualToString:@"quilt"])    return _selectedQuiltVersion;
    if ([loaderId isEqualToString:@"optifine"]) return _selectedOptiFineVersion;
    return nil;
}

- (void)setSelectedVersion:(NSString *)version forLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   self.selectedFabricVersion = version;
    else if ([loaderId isEqualToString:@"forge"])    self.selectedForgeVersion = version;
    else if ([loaderId isEqualToString:@"neoforge"]) self.selectedNeoForgeVersion = version;
    else if ([loaderId isEqualToString:@"quilt"])    self.selectedQuiltVersion = version;
    else if ([loaderId isEqualToString:@"optifine"]) {
        self.selectedOptiFineVersion = version;
        // 解析 packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
        if ([version containsString:@"\x1f"]) {
            NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
            if (parts.count >= 3) {
                self.selectedOptiFineType = parts[0];
                self.selectedOptiFinePatch = parts[1];
                self.selectedOptiFineFilename = parts[2];
            }
        }
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TextField

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // 用户开始手动编辑
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // 注意：变量名不能使用 "auto"，因为 auto 是 C/C++/Objective-C 的保留关键字
    // （存储类说明符），作为标识符会导致 "expected identifier or '('" 编译错误。
    // 改用 autoGeneratedName 以避免与关键字冲突。
    NSString *autoGeneratedName = [self generateVersionName];
    if (textField.text.length == 0) {
        _nameManuallyModified = NO;
        textField.text = autoGeneratedName;
    } else if (![textField.text isEqualToString:autoGeneratedName]) {
        _nameManuallyModified = YES;
    }
}

#pragma mark - CollectionView

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;  // 0: 加载器列表, 1: 选项
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section == 0) {
        return _loaders.count;
    }
    // section 1: 选项
    return [self currentOptions].count;
}

- (NSMutableArray *)currentOptions {
    NSMutableArray *opts = [NSMutableArray array];
    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        [opts addObject:@{ @"type": @"fabric_api" }];
    }
    if ([_selectedLoaderId isEqualToString:@"forge"]) {
        [opts addObject:@{ @"type": @"optifine_mod" }];
    }
    return opts;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        ModLoaderCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"LoaderCardCell" forIndexPath:indexPath];
        ModLoaderRow *row = _loaders[indexPath.item];

        BOOL isSelected = [_selectedLoaderId isEqualToString:row.identifier];

        // 计算选中版本的显示文本（OptiFine packed 格式提取 display）
        NSString *versionDisplay = nil;
        if (isSelected && ![row.identifier isEqualToString:@"vanilla"]) {
            NSString *selVer = [self selectedVersionForLoader:row.identifier];
            if (selVer.length > 0) {
                versionDisplay = selVer;
                if ([selVer containsString:@"\x1f"]) {
                    NSArray *parts = [selVer componentsSeparatedByString:@"\x1f"];
                    if (parts.count >= 4) versionDisplay = parts[3];
                    else if (parts.count >= 1) versionDisplay = parts[0];
                }
            }
        }

        // 兼容性 + 互斥判断
        BOOL incompatible = NO;
        NSString *reason = nil;
        if (!row.compatible) {
            incompatible = YES;
            reason = @"当前版本不支持";
        } else {
            reason = [self incompatibleReasonForLoaderId:row.identifier];
            if (reason) incompatible = YES;
        }

        [cell configureWithRow:row
                    isSelected:isSelected
          selectedVersionDisplay:versionDisplay
                    incompatible:incompatible
                         reason:reason];
        return cell;
    } else {
        // section 1: 附加选项（Fabric API / OptiFine 共存开关）
        ModLoaderSwitchCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"SwitchCardCell" forIndexPath:indexPath];
        NSMutableArray *opts = [self currentOptions];
        NSDictionary *opt = opts[indexPath.item];
        NSString *type = opt[@"type"];

        if ([type isEqualToString:@"fabric_api"]) {
            cell.titleLabel.text = @"同时安装 Fabric API";
            cell.descLabel.text = @"Fabric 模组的核心依赖库，建议保持开启";
            cell.switchControl.on = _installFabricAPI;
            cell.switchControl.tag = 1001;
        } else if ([type isEqualToString:@"optifine_mod"]) {
            cell.titleLabel.text = @"同时安装 OptiFine";
            cell.descLabel.text = @"作为 mod 安装到 mods 目录，与 Forge 共存";
            cell.switchControl.on = _installOptiFine;
            cell.switchControl.tag = 1002;
        } else {
            cell.titleLabel.text = @"";
            cell.descLabel.text = @"";
            cell.switchControl.on = NO;
            cell.switchControl.tag = 0;
        }
        [cell.switchControl removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.switchControl addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        return cell;
    }
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (kind == UICollectionElementKindSectionHeader) {
        ModLoaderSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
        if (indexPath.section == 0) {
            header.titleLabel.text = @"模组加载器";
        } else {
            // 附加选项 section 只有在 currentOptions 非空时才显示标题
            header.titleLabel.text = [self currentOptions].count > 0 ? @"附加选项" : @"";
        }
        return header;
    }
    return [UICollectionReusableView new];
}

- (void)switchChanged:(UISwitch *)sender {
    if (sender.tag == 1001) {
        _installFabricAPI = sender.on;
    } else if (sender.tag == 1002) {
        _installOptiFine = sender.on;
    }
    [self refreshVersionName];
    // 重新加载 section 0 让卡片选中边框和互斥状态同步刷新
    [_collectionView reloadSections:[NSIndexSet indexSetWithIndex:0]];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;

    ModLoaderRow *row = _loaders[indexPath.item];
    if (!row.compatible) return;

    NSString *reason = [self incompatibleReasonForLoaderId:row.identifier];
    if (reason) {
        [self showAlert:reason message:nil];
        return;
    }

    if ([row.identifier isEqualToString:@"vanilla"]) {
        _selectedLoaderId = @"vanilla";
        // 清空加载器版本（vanilla 无需版本号）
        _installOptiFine = NO;
        _installFabricAPI = NO;
        [self refreshVersionName];
        [collectionView reloadData];
        return;
    }

    // 切换加载器
    _selectedLoaderId = row.identifier;
    // 重置互斥选项
    if (![row.identifier isEqualToString:@"fabric"])  _installFabricAPI = NO;
    if (![row.identifier isEqualToString:@"forge"])   _installOptiFine = NO;
    if ([row.identifier isEqualToString:@"fabric"])   _installFabricAPI = YES;

    [self refreshVersionName];

    // 直接 push 版本选择页
    [self pushVersionPickerForLoader:row.identifier];
    [collectionView reloadData];
}

- (void)pushVersionPickerForLoader:(NSString *)loaderId {
    ModLoaderVersionPickerViewController *picker = [[ModLoaderVersionPickerViewController alloc] init];
    picker.loaderId = loaderId;
    picker.gameVersion = _gameVersion;
    picker.selectedVersion = [self selectedVersionForLoader:loaderId];

    __weak typeof(self) weakSelf = self;
    picker.onSelected = ^(NSString *version) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setSelectedVersion:version forLoader:loaderId];
        [strongSelf refreshVersionName];
        [strongSelf.collectionView reloadData];
    };
    picker.onCancelled = nil;

    [self.navigationController pushViewController:picker animated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
