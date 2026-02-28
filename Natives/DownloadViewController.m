#import "DownloadViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModService.h"
#import "ShaderService.h"
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
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import <QuartzCore/QuartzCore.h>

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

#pragma mark - 常量定义
static NSString * const kDownloadProgressKVOContext = @"DownloadProgressContext";
static NSInteger const kLoaderSelectionContainerTag = 9999;
static CGFloat const kDefaultCornerRadius = 16.0;
static CGFloat const kDefaultMargin = 12.0;
static CGFloat const kDefaultSmallMargin = 8.0;

#pragma mark - ModernAssetCell
@interface ModernAssetCell : UITableViewCell
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIStackView *tagsStack;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, copy) NSString *currentIconURL; // 修复cell复用图片错乱
@end

@implementation ModernAssetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
        self.blurView.layer.cornerRadius = kDefaultCornerRadius;
        self.blurView.layer.masksToBounds = YES;
        self.blurView.layer.borderWidth = 0.5;
        self.blurView.layer.borderColor = [UIColor separatorColor].CGColor;
        [self.contentView addSubview:self.blurView];
        
        self.contentContainer = [[UIView alloc] init];
        self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.blurView.contentView addSubview:self.contentContainer];
        
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 12.0;
        self.iconView.clipsToBounds = YES;
        self.iconView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.iconView.contentMode = UIViewContentModeScaleAspectFill;
        [self.contentContainer addSubview:self.iconView];
        
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.numberOfLines = 1;
        [self.contentContainer addSubview:self.titleLabel];
        
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 2;
        [self.contentContainer addSubview:self.descLabel];
        
        self.metaLabel = [[UILabel alloc] init];
        self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.metaLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        self.metaLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentContainer addSubview:self.metaLabel];
        
        self.tagsStack = [[UIStackView alloc] init];
        self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
        self.tagsStack.spacing = 6.0;
        self.tagsStack.distribution = UIStackViewDistributionFill;
        [self.contentContainer addSubview:self.tagsStack];
        
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        self.downloadButton.layer.cornerRadius = 20.0;
        [self.contentContainer addSubview:self.downloadButton];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:kDefaultMargin],
            [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-kDefaultMargin],
            [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
            
            [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:kDefaultMargin],
            [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:kDefaultMargin],
            [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-kDefaultMargin],
            [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-kDefaultMargin],
            
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:56],
            [self.iconView.heightAnchor constraintEqualToConstant:56],
            
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:kDefaultMargin],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.topAnchor],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-8],
            
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.descLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
            
            [self.metaLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.metaLabel.topAnchor constraintEqualToAnchor:self.descLabel.bottomAnchor constant:2],
            [self.metaLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor],
            
            [self.tagsStack.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.tagsStack.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:4],
            [self.tagsStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.downloadButton.leadingAnchor constant:-8],
            
            [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
            [self.downloadButton.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.downloadButton.widthAnchor constraintEqualToConstant:40],
            [self.downloadButton.heightAnchor constraintEqualToConstant:40]
        ]];
    }
    return self;
}

#pragma mark - 公共配置方法（修复重复代码）
- (void)configureCommonWithData:(NSDictionary *)data iconName:(NSString *)iconName tintColor:(UIColor *)color {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    // 下载量格式化
    NSString *author = data[@"author"] ?: @"Unknown";
    NSNumber *downloads = data[@"downloads"];
    NSString *downloadsStr = @"";
    if (downloads) {
        NSInteger dl = [downloads integerValue];
        if (dl >= 1000000) {
            downloadsStr = [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
        } else if (dl >= 1000) {
            downloadsStr = [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
        } else {
            downloadsStr = [NSString stringWithFormat:@"%ld", (long)dl];
        }
    }
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    // 标签配置
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *categories = data[@"categories"] ?: @[];
    for (NSInteger i = 0; i < MIN(3, categories.count); i++) {
        NSString *cat = categories[i];
        if ([cat isKindOfClass:[NSString class]]) {
            UILabel *tag = [self createTagLabel:cat];
            [self.tagsStack addArrangedSubview:tag];
        }
    }
    
    // 图标加载（修复复用错乱）
    self.currentIconURL = data[@"imageUrl"] ?: data[@"icon_url"];
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = color;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    
    if (self.currentIconURL.length > 0) {
        NSString *targetURL = self.currentIconURL;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:targetURL]];
            UIImage *image = data ? [UIImage imageWithData:data] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.currentIconURL isEqualToString:targetURL] && image) {
                    self.iconView.image = image;
                    self.iconView.contentMode = UIViewContentModeScaleAspectFill;
                }
            });
        });
    }
}

- (void)configureWithMod:(NSDictionary *)mod {
    [self configureCommonWithData:mod iconName:@"puzzlepiece.fill" tintColor:[UIColor systemOrangeColor]];
}

- (void)configureWithShader:(NSDictionary *)shader {
    [self configureCommonWithData:shader iconName:@"paintbrush.fill" tintColor:[UIColor systemPurpleColor]];
}

- (UILabel *)createTagLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor tertiaryLabelColor];
    label.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    label.layer.cornerRadius = 4.0;
    label.layer.masksToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    
    [label.widthAnchor constraintGreaterThanOrEqualToConstant:24].active = YES;
    [label.heightAnchor constraintEqualToConstant:18].active = YES;
    [label.layoutMarginsGuide.leadingAnchor constraintEqualToAnchor:label.leadingAnchor constant:4].active = YES;
    [label.layoutMarginsGuide.trailingAnchor constraintEqualToAnchor:label.trailingAnchor constant:-4].active = YES;
    
    return label;
}

@end

#pragma mark - LoaderCell
@interface LoaderCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *separator;
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 10.0;
        self.iconView.clipsToBounds = YES;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:self.iconView];
        
        self.nameLabel = [[UILabel alloc] init];
        self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.nameLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        self.nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.nameLabel];
        
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 2;
        [self.contentView addSubview:self.descLabel];
        
        self.statusLabel = [[UILabel alloc] init];
        self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.statusLabel.textAlignment = NSTextAlignmentRight;
        self.statusLabel.hidden = YES;
        [self.contentView addSubview:self.statusLabel];
        
        self.separator = [[UIView alloc] init];
        self.separator.translatesAutoresizingMaskIntoConstraints = NO;
        self.separator.backgroundColor = [UIColor separatorColor];
        [self.contentView addSubview:self.separator];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:48],
            [self.iconView.heightAnchor constraintEqualToConstant:48],
            
            [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
            [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.statusLabel.leadingAnchor constant:-8],
            
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:4],
            [self.descLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],
            [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-12],
            
            [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [self.statusLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            
            [self.separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
            [self.separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [self.separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [self.separator.heightAnchor constraintEqualToConstant:0.5]
        ]];
    }
    return self;
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    self.contentView.backgroundColor = selected ? [UIColor tertiarySystemBackgroundColor] : [UIColor clearColor];
    self.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    self.tintColor = selected ? [UIColor systemGreenColor] : nil;
}

- (void)setIncompatible:(BOOL)incompatible {
    self.statusLabel.hidden = !incompatible;
    self.statusLabel.text = incompatible ? @"不兼容" : nil;
    self.statusLabel.textColor = [UIColor systemRedColor];
    
    self.nameLabel.textColor = incompatible ? [UIColor tertiaryLabelColor] : [UIColor labelColor];
    self.descLabel.textColor = incompatible ? [UIColor quaternaryLabelColor] : [UIColor secondaryLabelColor];
    self.iconView.alpha = incompatible ? 0.5 : 1.0;
    self.userInteractionEnabled = !incompatible;
}

@end

#pragma mark - LoaderSelectionViewController
@interface LoaderSelectionViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion);
@property (nonatomic, copy) void (^cancelled)(void);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *optionsContainer;
@property (nonatomic, strong) UISwitch *fabricAPISwitch;
@property (nonatomic, strong) UISwitch *optiFineSwitch;
@property (nonatomic, strong) UILabel *fabricAPILabel;
@property (nonatomic, strong) UILabel *optiFineLabel;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) NSString *selectedLoader;
@property (nonatomic, strong) NSString *gameVersion;
@property (nonatomic, strong) NSArray *loaderVersions;
@property (nonatomic, strong) UITableView *versionTableView;
@property (nonatomic, strong) NSString *selectedLoaderVersion;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, assign) BOOL isCardStyle;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = self.isCardStyle ? [UIColor clearColor] : [UIColor systemBackgroundColor];
    self.modalPresentationStyle = self.isCardStyle ? UIModalPresentationOverFullScreen : UIModalPresentationFullScreen;
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupOptionsContainer];
    [self setupVersionTableView];
    [self setupInstallButton];
    [self setupNavigation];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 76;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[LoaderCell class] forCellReuseIdentifier:@"LoaderCell"];
    [self.view addSubview:self.tableView];
    
    CGFloat topConstant = self.isCardStyle ? 60 : 0;
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:topConstant],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.heightAnchor constraintEqualToConstant:380]
    ]];
}

- (void)setupOptionsContainer {
    self.optionsContainer = [[UIView alloc] init];
    self.optionsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.optionsContainer.layer.cornerRadius = 12.0;
    self.optionsContainer.hidden = YES;
    [self.view addSubview:self.optionsContainer];
    
    self.fabricAPILabel = [[UILabel alloc] init];
    self.fabricAPILabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.fabricAPILabel.text = @"同时安装 Fabric API";
    self.fabricAPILabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.fabricAPILabel.textColor = [UIColor labelColor];
    self.fabricAPILabel.hidden = YES;
    [self.optionsContainer addSubview:self.fabricAPILabel];
    
    self.fabricAPISwitch = [[UISwitch alloc] init];
    self.fabricAPISwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.fabricAPISwitch.on = YES;
    self.fabricAPISwitch.hidden = YES;
    [self.optionsContainer addSubview:self.fabricAPISwitch];
    
    self.optiFineLabel = [[UILabel alloc] init];
    self.optiFineLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.optiFineLabel.text = @"同时安装 OptiFine";
    self.optiFineLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.optiFineLabel.textColor = [UIColor labelColor];
    self.optiFineLabel.hidden = YES;
    [self.optionsContainer addSubview:self.optiFineLabel];
    
    self.optiFineSwitch = [[UISwitch alloc] init];
    self.optiFineSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.optiFineSwitch.on = NO;
    self.optiFineSwitch.hidden = YES;
    [self.optionsContainer addSubview:self.optiFineSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.optionsContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.optionsContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.optionsContainer.topAnchor constraintEqualToAnchor:self.tableView.bottomAnchor constant:kDefaultSmallMargin],
        [self.optionsContainer.heightAnchor constraintEqualToConstant:50],
        
        [self.fabricAPILabel.leadingAnchor constraintEqualToAnchor:self.optionsContainer.leadingAnchor constant:16],
        [self.fabricAPILabel.centerYAnchor constraintEqualToAnchor:self.optionsContainer.centerYAnchor],
        
        [self.fabricAPISwitch.trailingAnchor constraintEqualToAnchor:self.optionsContainer.trailingAnchor constant:-16],
        [self.fabricAPISwitch.centerYAnchor constraintEqualToAnchor:self.optionsContainer.centerYAnchor],
        
        [self.optiFineLabel.leadingAnchor constraintEqualToAnchor:self.optionsContainer.leadingAnchor constant:16],
        [self.optiFineLabel.centerYAnchor constraintEqualToAnchor:self.optionsContainer.centerYAnchor],
        
        [self.optiFineSwitch.trailingAnchor constraintEqualToAnchor:self.optionsContainer.trailingAnchor constant:-16],
        [self.optiFineSwitch.centerYAnchor constraintEqualToAnchor:self.optionsContainer.centerYAnchor]
    ]];
}

- (void)setupVersionTableView {
    self.versionTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.versionTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionTableView.backgroundColor = [UIColor clearColor];
    self.versionTableView.dataSource = self;
    self.versionTableView.delegate = self;
    self.versionTableView.rowHeight = 44;
    self.versionTableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.versionTableView.hidden = YES;
    [self.versionTableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"VersionCell"];
    [self.view addSubview:self.versionTableView];
    
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.versionTableView.topAnchor constraintEqualToAnchor:self.optionsContainer.bottomAnchor constant:kDefaultSmallMargin],
        [self.versionTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.versionTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-70],
        
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.versionTableView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.versionTableView.centerYAnchor]
    ]];
}

- (void)setupInstallButton {
    self.installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.installButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.installButton setTitle:@"安装" forState:UIControlStateNormal];
    self.installButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.installButton.backgroundColor = [UIColor systemGreenColor];
    [self.installButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.installButton.layer.cornerRadius = 10.0;
    [self.installButton addTarget:self action:@selector(installButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.installButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.installButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.installButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.installButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.installButton.heightAnchor constraintEqualToConstant:50]
    ]];
}

- (void)setupNavigation {
    if (self.isCardStyle) {
        UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        [closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        closeButton.tintColor = [UIColor secondaryLabelColor];
        [closeButton addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
        
        [self.view addSubview:closeButton];
        [NSLayoutConstraint activateConstraints:@[
            [closeButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
            [closeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
            [closeButton.widthAnchor constraintEqualToConstant:32],
            [closeButton.heightAnchor constraintEqualToConstant:32]
        ]];
        
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.text = self.title;
        titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        titleLabel.textColor = [UIColor labelColor];
        [self.view addSubview:titleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
            [titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor]
        ]];
    } else {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" 
                                                                                style:UIBarButtonItemStylePlain 
                                                                               target:self 
                                                                               action:@selector(cancel)];
    }
}

- (void)cancel {
    !self.cancelled ?: self.cancelled();
}

- (void)installButtonTapped {
    if (!self.selectedLoader) {
        [self showAlert:@"请选择安装方式" message:nil];
        return;
    }
    
    if (![self.selectedLoader isEqualToString:@"vanilla"] && !self.selectedLoaderVersion.length) {
        [self showAlert:@"请选择版本" message:nil];
        return;
    }
    
    BOOL installFabricAPI = [self.selectedLoader isEqualToString:@"fabric"] && self.fabricAPISwitch.isOn;
    BOOL installOptiFine = [self.selectedLoader isEqualToString:@"forge"] && self.optiFineSwitch.isOn;
    
    !self.completion ?: self.completion(self.selectedLoader, installFabricAPI, installOptiFine, self.selectedLoaderVersion);
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)loadVersionsForLoader:(NSString *)loaderId {
    self.loaderVersions = nil;
    self.selectedLoaderVersion = nil;
    [self.versionTableView reloadData];
    self.versionTableView.hidden = NO;
    [self.loadingIndicator startAnimating];
    
    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"quilt"]) {
        [self loadFabricVersions:loaderId];
    } else if ([loaderId isEqualToString:@"forge"]) {
        [self loadForgeVersions];
    } else if ([loaderId isEqualToString:@"neoforge"]) {
        [self loadNeoForgeVersions];
    }
}

- (void)loadFabricVersions:(NSString *)loaderType {
    NSString *urlString = [NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@", self.gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [strongSelf.loadingIndicator stopAnimating];
            if (!data || error) {
                [strongSelf showNoVersionsAlert:loaderType];
                return;
            }
            
            NSError *jsonError;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!versions || jsonError || ![versions isKindOfClass:[NSArray class]]) {
                [strongSelf showNoVersionsAlert:loaderType];
                return;
            }
            
            NSMutableSet *versionSet = [NSMutableSet set];
            for (NSDictionary *ver in versions) {
                if (![ver isKindOfClass:[NSDictionary class]]) continue;
                NSString *loaderVersion = ver[@"loader"][@"version"];
                if (loaderVersion.length) [versionSet addObject:loaderVersion];
            }
            
            NSArray *sortedVersions = [versionSet.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
                return [v2 compare:v1 options:NSNumericSearch];
            }];
            
            strongSelf.loaderVersions = sortedVersions;
            [strongSelf.versionTableView reloadData];
            
            if (sortedVersions.count == 0) {
                [strongSelf showNoVersionsAlert:loaderType];
            }
        });
    }];
    [task resume];
}

- (void)loadForgeVersions {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *commonVersions = @{
            @"1.21.1": @[@"52.0.23"],
            @"1.20.4": @[@"49.1.0"],
            @"1.20.1": @[@"47.2.0", @"47.1.3", @"47.1.0"],
            @"1.20": @[@"46.0.14"],
            @"1.19.4": @[@"45.2.0", @"45.1.0"],
            @"1.19.2": @[@"43.3.0", @"43.2.0"],
            @"1.18.2": @[@"40.2.0", @"40.1.0"],
            @"1.16.5": @[@"36.2.34", @"36.2.0"],
            @"1.12.2": @[@"14.23.5.2860"],
            @"1.8.9": @[@"11.15.1.2318"]
        };
        
        NSArray *versions = commonVersions[self.gameVersion] ?: @[];
        NSArray *sortedVersions = [versions sortedArrayUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
            return [v2 compare:v1 options:NSNumericSearch];
        }];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [strongSelf.loadingIndicator stopAnimating];
            if (sortedVersions.count > 0) {
                strongSelf.loaderVersions = sortedVersions;
                [strongSelf.versionTableView reloadData];
            } else {
                [strongSelf showNoVersionsAlert:@"Forge"];
            }
        });
    });
}

- (void)loadNeoForgeVersions {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *commonVersions = @{
            @"1.21.1": @[@"21.1.0"],
            @"1.20.4": @[@"20.4.237"],
            @"1.20.1": @[@"47.1.106", @"47.1.99"]
        };
        
        NSArray *versions = commonVersions[self.gameVersion] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [strongSelf.loadingIndicator stopAnimating];
            if (versions.count > 0) {
                strongSelf.loaderVersions = versions;
                [strongSelf.versionTableView reloadData];
            } else {
                [strongSelf showNoVersionsAlert:@"NeoForge"];
            }
        });
    });
}

- (void)showNoVersionsAlert:(NSString *)loaderName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ 暂无可用的版本", loaderName]
                                                                   message:[NSString stringWithFormat:@"当前选择的 Minecraft %@ 没有可用的 %@ 版本", self.gameVersion, loaderName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableView Delegate & DataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return tableView == self.tableView ? self.loaders.count : self.loaderVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.tableView) {
        LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
        NSDictionary *loader = self.loaders[indexPath.row];
        
        cell.nameLabel.text = loader[@"name"];
        cell.descLabel.text = loader[@"desc"];
        cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"]];
        cell.iconView.tintColor = loader[@"color"];
        cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
        
        BOOL isSelected = [self.selectedLoader isEqualToString:loader[@"id"]];
        [cell setSelected:isSelected animated:NO];
        [cell setIncompatible:[self isLoaderIncompatible:loader[@"id"]]];
        
        return cell;
    } else {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell" forIndexPath:indexPath];
        NSString *version = self.loaderVersions[indexPath.row];
        cell.textLabel.text = version;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cell.accessoryType = [self.selectedLoaderVersion isEqualToString:version] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = [UIColor systemGreenColor];
        return cell;
    }
}

- (BOOL)isLoaderIncompatible:(NSString *)loaderId {
    if (!self.gameVersion || [loaderId isEqualToString:@"vanilla"]) return NO;
    
    NSArray *versionComponents = [self.gameVersion componentsSeparatedByString:@"."];
    if (versionComponents.count < 2) return NO;
    
    NSInteger majorVersion = [versionComponents[0] integerValue];
    NSInteger minorVersion = [versionComponents[1] integerValue];
    NSInteger patchVersion = 0;
    
    if (versionComponents.count >= 3) {
        NSString *patchStr = versionComponents[2];
        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
        NSMutableString *patchNum = [NSMutableString string];
        for (NSInteger i = 0; i < patchStr.length; i++) {
            unichar c = [patchStr characterAtIndex:i];
            if ([digits characterIsMember:c]) [patchNum appendFormat:@"%c", c];
            else break;
        }
        patchVersion = [patchNum integerValue];
    }
    
    NSInteger versionNumber = majorVersion * 10000 + minorVersion * 100 + patchVersion;
    if ([loaderId isEqualToString:@"fabric"]) return versionNumber < 11400;
    if ([loaderId isEqualToString:@"quilt"]) return versionNumber < 11800;
    if ([loaderId isEqualToString:@"neoforge"]) return versionNumber < 12001;
    return NO;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (tableView == self.tableView) {
        NSDictionary *loader = self.loaders[indexPath.row];
        NSString *loaderId = loader[@"id"];
        
        if ([self isLoaderIncompatible:loaderId]) return;
        
        if ([self.selectedLoader isEqualToString:loaderId]) {
            self.selectedLoader = nil;
            self.optionsContainer.hidden = YES;
            self.versionTableView.hidden = YES;
            self.selectedLoaderVersion = nil;
            self.loaderVersions = nil;
        } else {
            self.selectedLoader = loaderId;
            self.optionsContainer.hidden = NO;
            self.optionsContainer.alpha = 0;
            [UIView animateWithDuration:0.3 animations:^{
                self.optionsContainer.alpha = 1;
            }];
            
            self.selectedLoaderVersion = nil;
            self.loaderVersions = nil;
            [self.versionTableView reloadData];
            [self configureOptionsForLoader:loaderId];
        }
        [tableView reloadData];
    } else {
        if (indexPath.row < self.loaderVersions.count) {
            self.selectedLoaderVersion = self.loaderVersions[indexPath.row];
            [tableView reloadData];
        }
    }
}

- (void)configureOptionsForLoader:(NSString *)loaderId {
    self.fabricAPILabel.hidden = YES;
    self.fabricAPISwitch.hidden = YES;
    self.optiFineLabel.hidden = YES;
    self.optiFineSwitch.hidden = YES;
    self.versionTableView.hidden = YES;
    
    if ([loaderId isEqualToString:@"fabric"]) {
        self.fabricAPILabel.hidden = NO;
        self.fabricAPISwitch.hidden = NO;
        [self loadVersionsForLoader:@"fabric"];
    } else if ([loaderId isEqualToString:@"forge"]) {
        self.optiFineLabel.hidden = NO;
        self.optiFineSwitch.hidden = NO;
        [self loadVersionsForLoader:@"forge"];
    } else if ([loaderId isEqualToString:@"neoforge"]) {
        [self loadVersionsForLoader:@"neoforge"];
    } else if ([loaderId isEqualToString:@"quilt"]) {
        [self loadVersionsForLoader:@"quilt"];
    }
}

@end

#pragma mark - DownloadViewController
@interface DownloadViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, ModVersionViewControllerDelegate, ShaderVersionViewControllerDelegate>

@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UISegmentedControl *versionFilterSegment;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIButton *filterButton;
@property (nonatomic, strong) UICollectionView *versionCollectionView;
@property (nonatomic, strong) UITableView *modTableView;
@property (nonatomic, strong) UITableView *shaderTableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, strong) NSArray *filteredVersions;
@property (nonatomic, strong) NSMutableArray *modList;
@property (nonatomic, strong) NSMutableArray *shaderList;

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
@property (nonatomic, strong) UIAlertController *downloadingAlert;

// 修复进度计算静态变量共享问题
@property (nonatomic, assign) CGFloat lastMsTime;
@property (nonatomic, assign) NSUInteger lastSecTime;
@property (nonatomic, assign) NSInteger lastCompletedUnitCount;

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.modList = [NSMutableArray array];
    self.shaderList = [NSMutableArray array];
    self.currentModOffset = 0;
    self.currentShaderOffset = 0;
    self.hasMoreMods = YES;
    self.hasMoreShaders = YES;
    self.currentSortField = @"follows";
    
    [self setupUI];
    [self switchToTab:0];
    [self loadVersionList];
}

- (void)dealloc {
    // 修复KVO内存泄漏，移除观察者
    [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted" context:(void *)kDownloadProgressKVOContext];
}

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupModTableView];
    [self setupShaderTableView];
    [self setupLoadingIndicator];
    [self setupEmptyLabel];
}

- (void)setupTabSegment {
    self.tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"版本下载", @"模组下载", @"光影下载"]];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.versionFilterSegment.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        [self.versionFilterSegment.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionFilterSegment.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];
}

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = @"搜索...";
    self.searchBar.delegate = self;
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.hidden = YES;
    [self.view addSubview:self.searchBar];
    
    self.filterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.filterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    [self.filterButton addTarget:self action:@selector(showFilterOptions) forControlEvents:UIControlEventTouchUpInside];
    self.filterButton.hidden = YES;
    [self.view addSubview:self.filterButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.filterButton.leadingAnchor constant:-8],
        
        [self.filterButton.centerYAnchor constraintEqualToAnchor:self.searchBar.centerYAnchor],
        [self.filterButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.filterButton.widthAnchor constraintEqualToConstant:44],
        [self.filterButton.heightAnchor constraintEqualToConstant:44]
    ]];
}

- (void)setupVersionCollectionView {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionVertical;
    layout.minimumInteritemSpacing = 10.0;
    layout.minimumLineSpacing = 10.0;
    layout.sectionInset = UIEdgeInsetsMake(10, 10, 10, 10);
    
    // 修复自适应布局
    CGFloat screenWidth = UIScreen.mainScreen.bounds.size.width;
    CGFloat itemWidth = (screenWidth - 40) / 3.0;
    layout.itemSize = CGSizeMake(floor(itemWidth), 120);
    
    self.versionCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.versionCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionCollectionView.backgroundColor = [UIColor clearColor];
    self.versionCollectionView.dataSource = self;
    self.versionCollectionView.delegate = self;
    [self.versionCollectionView registerClass:[VersionCardCell class] forCellWithReuseIdentifier:@"VersionCard"];
    [self.view addSubview:self.versionCollectionView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.versionCollectionView.topAnchor constraintEqualToAnchor:self.versionFilterSegment.bottomAnchor constant:8],
        [self.versionCollectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.versionCollectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.versionCollectionView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupModTableView {
    self.modTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.modTableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.modTableView.backgroundColor = [UIColor clearColor];
    self.modTableView.dataSource = self;
    self.modTableView.delegate = self;
    self.modTableView.rowHeight = 100;
    self.modTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.modTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ModCell"];
    self.modTableView.hidden = YES;
    [self.view addSubview:self.modTableView];
    
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshModList) forControlEvents:UIControlEventValueChanged];
    self.modTableView.refreshControl = refreshControl;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.modTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
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
    self.shaderTableView.rowHeight = 100;
    self.shaderTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.shaderTableView registerClass:[ModernAssetCell class] forCellReuseIdentifier:@"ShaderCell"];
    self.shaderTableView.hidden = YES;
    [self.view addSubview:self.shaderTableView];
    
    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    [refreshControl addTarget:self action:@selector(refreshShaderList) forControlEvents:UIControlEventValueChanged];
    self.shaderTableView.refreshControl = refreshControl;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.shaderTableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [self.shaderTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.shaderTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.shaderTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
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
    self.versionFilterSegment.hidden = (index != 0);
    self.versionCollectionView.hidden = (index != 0);
    self.searchBar.hidden = (index == 0);
    self.filterButton.hidden = (index == 0);
    self.modTableView.hidden = (index != 1);
    self.shaderTableView.hidden = (index != 2);
    
    self.emptyLabel.hidden = YES;
    if (index == 1 && self.modList.count == 0) {
        [self loadModList];
    } else if (index == 2 && self.shaderList.count == 0) {
        [self loadShaderList];
    }
}

#pragma mark - Loader Selection Popup
- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    UIView *fullScreenContainer = [[UIView alloc] initWithFrame:self.view.bounds];
    fullScreenContainer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    fullScreenContainer.tag = kLoaderSelectionContainerTag;
    fullScreenContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissLoaderSelection:)];
    tapGesture.cancelsTouchesInView = NO;
    [fullScreenContainer addGestureRecognizer:tapGesture];
    
    UIView *contentCard = [[UIView alloc] init];
    contentCard.translatesAutoresizingMaskIntoConstraints = NO;
    contentCard.backgroundColor = [UIColor clearColor];
    contentCard.layer.cornerRadius = 20.0;
    contentCard.layer.masksToBounds = YES;
    
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    blurView.layer.cornerRadius = 20.0;
    blurView.layer.masksToBounds = YES;
    
    [contentCard addSubview:blurView];
    [fullScreenContainer addSubview:contentCard];
    [self.view addSubview:fullScreenContainer];
    
    [NSLayoutConstraint activateConstraints:@[
        [blurView.topAnchor constraintEqualToAnchor:contentCard.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:contentCard.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:contentCard.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:contentCard.bottomAnchor],
        
        [contentCard.topAnchor constraintEqualToAnchor:fullScreenContainer.safeAreaLayoutGuide.topAnchor constant:20],
        [contentCard.leadingAnchor constraintEqualToAnchor:fullScreenContainer.leadingAnchor constant:20],
        [contentCard.trailingAnchor constraintEqualToAnchor:fullScreenContainer.trailingAnchor constant:-20],
        [contentCard.bottomAnchor constraintEqualToAnchor:fullScreenContainer.safeAreaLayoutGuide.bottomAnchor constant:-20]
    ]];
    
    LoaderSelectionViewController *loaderSelectionVC = [[LoaderSelectionViewController alloc] init];
    loaderSelectionVC.gameVersion = version[@"id"];
    loaderSelectionVC.isCardStyle = YES;
    
    __weak typeof(self) weakSelf = self;
    loaderSelectionVC.completion = ^(NSString *loaderType, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        [strongSelf removeLoaderSelectionContainer];
        [strongSelf proceedWithVersion:version 
                            loaderType:loaderType 
                      installFabricAPI:installFabricAPI 
                       installOptiFine:installOptiFine 
                         loaderVersion:loaderVersion];
    };
    
    loaderSelectionVC.cancelled = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf removeLoaderSelectionContainer];
    };
    
    [self addChildViewController:loaderSelectionVC];
    [contentCard addSubview:loaderSelectionVC.view];
    loaderSelectionVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [NSLayoutConstraint activateConstraints:@[
        [loaderSelectionVC.view.topAnchor constraintEqualToAnchor:contentCard.topAnchor],
        [loaderSelectionVC.view.leadingAnchor constraintEqualToAnchor:contentCard.leadingAnchor],
        [loaderSelectionVC.view.trailingAnchor constraintEqualToAnchor:contentCard.trailingAnchor],
        [loaderSelectionVC.view.bottomAnchor constraintEqualToAnchor:contentCard.bottomAnchor]
    ]];
    
    [loaderSelectionVC didMoveToParentViewController:self];
    
    fullScreenContainer.alpha = 0;
    contentCard.transform = CGAffineTransformMakeScale(0.9, 0.9);
    
    [UIView animateWithDuration:0.3 animations:^{
        fullScreenContainer.alpha = 1;
        contentCard.transform = CGAffineTransformIdentity;
    }];
    
    self.tabSegment.userInteractionEnabled = NO;
    self.versionCollectionView.userInteractionEnabled = NO;
    self.versionFilterSegment.userInteractionEnabled = NO;
}

- (void)removeLoaderSelectionContainer {
    UIView *container = [self.view viewWithTag:kLoaderSelectionContainerTag];
    if (!container) return;
    
    [UIView animateWithDuration:0.2 animations:^{
        container.alpha = 0;
    } completion:^(BOOL finished) {
        for (UIViewController *childVC in [self.childViewControllers copy]) {
            if ([childVC isKindOfClass:[LoaderSelectionViewController class]]) {
                [childVC willMoveToParentViewController:nil];
                [childVC.view removeFromSuperview];
                [childVC removeFromParentViewController];
            }
        }
        [container removeFromSuperview];
    }];
    
    self.tabSegment.userInteractionEnabled = YES;
    self.versionCollectionView.userInteractionEnabled = YES;
    self.versionFilterSegment.userInteractionEnabled = YES;
}

- (void)dismissLoaderSelection:(UITapGestureRecognizer *)gesture {
    CGPoint location = [gesture locationInView:gesture.view];
    UIView *contentCard = gesture.view.subviews.firstObject;
    
    if (contentCard && !CGRectContainsPoint(contentCard.frame, location)) {
        [self removeLoaderSelectionContainer];
        for (UIViewController *childVC in [self.childViewControllers copy]) {
            if ([childVC isKindOfClass:[LoaderSelectionViewController class]]) {
                !((LoaderSelectionViewController *)childVC).cancelled ?: ((LoaderSelectionViewController *)childVC).cancelled();
            }
        }
    }
}

#pragma mark - Data Loading
- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *versionManifestURL = [downloadSource isEqualToString:@"bmclapi"] 
        ? @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json"
        : @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    
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
                }
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
    NSMutableArray *filtered = [NSMutableArray array];
    
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        BOOL match = NO;
        
        switch (filterIndex) {
            case 0: match = YES; break;
            case 1: match = [type isEqualToString:@"release"]; break;
            case 2: match = [type isEqualToString:@"snapshot"]; break;
            case 3: match = [type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]; break;
        }
        if (match) [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
    self.emptyLabel.hidden = filtered.count > 0;
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
    
    if (self.currentModOffset == 0) [self.loadingIndicator startAnimating];
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentModOffset);
    if (self.currentSearchQuery.length) filters[@"query"] = self.currentSearchQuery;
    if (self.currentGameVersion.length) filters[@"version"] = self.currentGameVersion;
    if (self.currentModLoader.length) filters[@"loader"] = self.currentModLoader;
    filters[@"sort"] = self.currentSortField;
    
    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.modTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMore = NO;
            
            if (results) {
                if (strongSelf.currentModOffset == 0) [strongSelf.modList removeAllObjects];
                [strongSelf.modList addObjectsFromArray:results];
                strongSelf.hasMoreMods = (results.count >= 30);
                strongSelf.currentModOffset += results.count;
                
                [strongSelf.modTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.modList.count > 0);
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
    
    if (self.currentShaderOffset == 0) [self.loadingIndicator startAnimating];
    
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"limit"] = @30;
    filters[@"offset"] = @(self.currentShaderOffset);
    if (self.currentSearchQuery.length) filters[@"query"] = self.currentSearchQuery;
    if (self.currentGameVersion.length) filters[@"version"] = self.currentGameVersion;
    filters[@"sort"] = self.currentSortField;
    
    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [strongSelf.loadingIndicator stopAnimating];
            [strongSelf.shaderTableView.refreshControl endRefreshing];
            strongSelf.isLoadingMore = NO;
            
            if (results) {
                if (strongSelf.currentShaderOffset == 0) [strongSelf.shaderList removeAllObjects];
                [strongSelf.shaderList addObjectsFromArray:results];
                strongSelf.hasMoreShaders = (results.count >= 30);
                strongSelf.currentShaderOffset += results.count;
                
                [strongSelf.shaderTableView reloadData];
                strongSelf.emptyLabel.hidden = (strongSelf.shaderList.count > 0);
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

#pragma mark - Filter Options
- (void)showFilterOptions {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"筛选选项" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showGameVersionPicker];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"排序方式" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self showSortOptions];
    }]];
    
    if (tabIndex == 1) {
        [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self showModLoaderPicker];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self resetFilters];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showGameVersionPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择游戏版本" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *versions = @[@"全部版本", @"1.21.1", @"1.20.4", @"1.20.1", @"1.19.4", @"1.19.2", @"1.18.2", @"1.16.5", @"1.12.2", @"1.8.9"];
    
    for (NSString *version in versions) {
        [alert addAction:[UIAlertAction actionWithTitle:version style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.currentGameVersion = [version isEqualToString:@"全部版本"] ? nil : version;
            [self reloadCurrentList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSortOptions {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"排序方式" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSDictionary *sortOptions = @{
        @"关注度": @"follows",
        @"下载数": @"downloads",
        @"最近更新": @"updated",
        @"最新发布": @"newest",
        @"相关性": @"relevance"
    };
    
    for (NSString *title in sortOptions) {
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.currentSortField = sortOptions[title];
            [self reloadCurrentList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.filterButton;
        alert.popoverPresentationController.sourceRect = self.filterButton.bounds;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showModLoaderPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"模组加载器" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *loaderNames = @[@"全部", @"Fabric", @"Forge", @"Quilt", @"NeoForge"];
    NSArray *loaderValues = @[[NSNull null], @"fabric", @"forge", @"quilt", @"neoforge"];
    
    for (NSInteger i = 0; i < loaderNames.count; i++) {
        NSString *name = loaderNames[i];
        id value = loaderValues[i];
        [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.currentModLoader = (value == [NSNull null]) ? nil : value;
            [self reloadCurrentList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
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
    self.searchBar.text = nil;
    [self reloadCurrentList];
}

- (void)reloadCurrentList {
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 1) {
        self.currentModOffset = 0;
        [self.modList removeAllObjects];
        [self loadModList];
    } else if (tabIndex == 2) {
        self.currentShaderOffset = 0;
        [self.shaderList removeAllObjects];
        [self loadShaderList];
    }
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UISearchBarDelegate
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 1) [self searchMods:searchBar.text];
    else if (tabIndex == 2) [self searchShaders:searchBar.text];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = nil;
    self.currentSearchQuery = nil;
    [searchBar resignFirstResponder];
    [self reloadCurrentList];
}

#pragma mark - UICollectionView Delegate & DataSource
- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *versionId = version[@"id"];
    NSString *releaseTime = version[@"releaseTime"];
    NSString *versionType = version[@"type"];
    
    NSString *formattedDate = releaseTime.length >= 10 ? [releaseTime substringToIndex:10] : releaseTime;
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];
    
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    [self showLoaderSelectionForVersion:version];
}

#pragma mark - Installation
- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI installOptiFine:(BOOL)installOptiFine loaderVersion:(NSString *)loaderVersion {
    NSString *versionId = version[@"id"];
    if ([loaderType isEqualToString:@"vanilla"]) {
        [self downloadVanillaVersion:version];
    } else if ([loaderType isEqualToString:@"fabric"]) {
        [self installFabric:versionId loaderVersion:loaderVersion installAPI:installFabricAPI];
    } else if ([loaderType isEqualToString:@"forge"]) {
        [self installForge:versionId installOptiFine:installOptiFine];
    } else if ([loaderType isEqualToString:@"neoforge"]) {
        [self installNeoForge:versionId];
    } else if ([loaderType isEqualToString:@"quilt"]) {
        [self showError:@"Quilt 安装器暂未实现"];
    } else {
        [self showError:[NSString stringWithFormat:@"%@ 安装器暂未实现", loaderType]];
    }
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
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;
    
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    [self startVersionDownload:version];
}

- (void)startVersionDownload:(NSDictionary *)version {
    __weak DownloadViewController *weakSelf = self;
    
    self.downloadingAlert = [UIAlertController alertControllerWithTitle:@"下载中" message:@"正在准备下载..." preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *detailsAction = [UIAlertAction actionWithTitle:@"查看详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (weakSelf.downloadTask) {
            weakSelf.progressVC = [[DownloadProgressViewController alloc] initWithTask:weakSelf.downloadTask];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:weakSelf.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [weakSelf presentViewController:nav animated:YES completion:nil];
        }
    }];
    [self.downloadingAlert addAction:detailsAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        [strongSelf.downloadTask.progress cancel];
        [strongSelf.downloadTask.progress removeObserver:strongSelf forKeyPath:@"fractionCompleted" context:(void *)kDownloadProgressKVOContext];
        strongSelf.downloadTask = nil;
        strongSelf.view.userInteractionEnabled = YES;
        [strongSelf.loadingIndicator stopAnimating];
    }];
    [self.downloadingAlert addAction:cancelAction];
    
    [self presentViewController:self.downloadingAlert animated:YES completion:nil];
    [self.loadingIndicator startAnimating];
    
    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;
    
    self.downloadTask.retryCallback = ^(NSInteger retryCount, NSInteger maxRetryCount) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.downloadingAlert) return;
            strongSelf.downloadingAlert.message = [NSString stringWithFormat:@"下载失败，正在重试 (%ld/%ld)...", (long)retryCount, (long)maxRetryCount];
        });
    };
    
    self.downloadTask.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [strongSelf.downloadTask.progress removeObserver:strongSelf forKeyPath:@"fractionCompleted" context:(void *)kDownloadProgressKVOContext];
            strongSelf.view.userInteractionEnabled = YES;
            [strongSelf.loadingIndicator stopAnimating];
            strongSelf.downloadTask = nil;
            strongSelf.progressVC = nil;
            strongSelf.downloadingAlert = nil;
            
            [strongSelf showError:@"版本下载失败，请检查网络连接"];
        });
    };
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.downloadTask downloadVersion:version];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.downloadTask.progress addObserver:self 
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)kDownloadProgressKVOContext];
        });
    });
}

#pragma mark - Fabric Installation
- (void)installFabric:(NSString *)gameVersion loaderVersion:(NSString *)loaderVersion installAPI:(BOOL)installAPI {
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在安装 Fabric"
                                                                              message:[NSString stringWithFormat:@"游戏版本: %@\n加载器版本: %@", gameVersion, loaderVersion]
                                                                       preferredStyle:UIAlertControllerStyleAlert];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:downloadingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:downloadingAlert.view.centerYAnchor constant:40]
    ]];
    [indicator startAnimating];
    
    [self presentViewController:downloadingAlert animated:YES completion:nil];
    
    NSString *urlString = [NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@/%@/profile/json", gameVersion, loaderVersion];
    NSURL *url = [NSURL URLWithString:urlString];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            if (!data || error) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showError:[NSString stringWithFormat:@"Fabric 安装失败: %@", error.localizedDescription ?: @"网络错误"]];
                }];
                return;
            }
            
            NSError *jsonError;
            NSDictionary *profileJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!profileJson || jsonError) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showError:@"解析 Fabric 配置失败"];
                }];
                return;
            }
            
            NSString *versionId = profileJson[@"id"];
            if (!versionId.length) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showError:@"无效的 Fabric 版本配置"];
                }];
                return;
            }
            
            // 修复路径非空判断
            const char *gameDirChar = getenv("POJAV_GAME_DIR");
            if (!gameDirChar) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showError:@"游戏目录未配置"];
                }];
                return;
            }
            
            NSString *gameDir = [NSString stringWithUTF8String:gameDirChar];
            NSString *jsonDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
            NSString *jsonPath = [jsonDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
            
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *dirError;
            if (![fm createDirectoryAtPath:jsonDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showError:[NSString stringWithFormat:@"创建目录失败: %@", dirError.localizedDescription]];
                }];
                return;
            }
            
            NSError *saveError;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:NSJSONWritingPrettyPrinted error:&saveError];
            if (![jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError]) {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showError:[NSString stringWithFormat:@"保存配置失败: %@", saveError.localizedDescription]];
                }];
                return;
            }
            
            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;
            
            if (installAPI) {
                [strongSelf downloadFabricAPI:gameVersion completion:^(BOOL success, NSError *apiError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                            if (success) {
                                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Fabric %@ 安装成功\nFabric API 已自动安装", loaderVersion]];
                            } else {
                                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Fabric %@ 安装成功\nFabric API 安装失败: %@", loaderVersion, apiError.localizedDescription]];
                            }
                        }];
                    });
                }];
            } else {
                [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                    [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Fabric %@ 安装成功", loaderVersion]];
                }];
            }
        });
    }];
    [task resume];
}

- (void)downloadFabricAPI:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"version"] = gameVersion;
    
    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        if (error || results.count == 0) {
            !completion ?: completion(NO, error ?: [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"未找到 Fabric API"}]);
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
            !completion ?: completion(NO, [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"未找到合适的 Fabric API 版本"}]);
            return;
        }
        
        [[ModrinthAPI sharedInstance] getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
            if (versionError || versions.count == 0) {
                !completion ?: completion(NO, versionError ?: [NSError errorWithDomain:@"DownloadError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"获取 Fabric API 版本失败"}]);
                return;
            }
            
            ModVersion *matchingVersion = nil;
            for (ModVersion *ver in versions) {
                if ([ver.gameVersions containsObject:gameVersion]) {
                    matchingVersion = ver;
                    break;
                }
            }
            if (!matchingVersion) matchingVersion = versions.firstObject;
            
            [weakSelf downloadModVersion:matchingVersion modInfo:fabricAPI completion:completion];
        }];
    }];
}

- (void)downloadModVersion:(ModVersion *)version modInfo:(NSDictionary *)modInfo completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *downloadURL = version.primaryFile[@"url"];
    NSString *filename = version.primaryFile[@"filename"];
    
    if (!downloadURL.length) {
        !completion ?: completion(NO, [NSError errorWithDomain:@"DownloadError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"无效的下载链接"}]);
        return;
    }
    
    // 修复下载时profile切换问题
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    const char *gameDirChar = getenv("POJAV_GAME_DIR");
    if (!gameDirChar) {
        !completion ?: completion(NO, [NSError errorWithDomain:@"DownloadError" code:5 userInfo:@{NSLocalizedDescriptionKey: @"游戏目录未配置"}]);
        return;
    }
    
    NSString *gameDir = [NSString stringWithUTF8String:gameDirChar];
    NSString *profileDir = [gameDir stringByAppendingPathComponent:profileName];
    NSString *modsDir = [profileDir stringByAppendingPathComponent:@"mods"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError;
    if (![fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        !completion ?: completion(NO, dirError);
        return;
    }
    
    NSString *savePath = [modsDir stringByAppendingPathComponent:filename];
    NSURL *url = [NSURL URLWithString:downloadURL];
    
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (error || !location) {
            !completion ?: completion(NO, error);
            return;
        }
        
        [fm removeItemAtPath:savePath error:nil];
        NSError *moveError;
        BOOL success = [fm moveItemAtPath:location.path toPath:savePath error:&moveError];
        !completion ?: completion(success, moveError);
    }];
    [downloadTask resume];
}

#pragma mark - Forge Installation
- (void)installForge:(NSString *)gameVersion installOptiFine:(BOOL)installOptiFine {
    ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
    forgeVC.gameVersion = gameVersion;
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, NSError *) = ^(BOOL success, NSString *profileName, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (success) {
            if (installOptiFine) {
                [strongSelf downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (optiSuccess) {
                            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Forge 安装成功\nOptiFine 已自动安装\n配置文件: %@", profileName]];
                        } else {
                            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Forge 安装成功\nOptiFine 安装失败: %@\n配置文件: %@", optiError.localizedDescription, profileName]];
                        }
                    });
                }];
            } else {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Forge 安装成功\n配置文件: %@", profileName]];
            }
        } else {
            [strongSelf showError:error.localizedDescription ?: @"Forge 安装失败"];
        }
    };
    forgeVC.completionHandler = completion;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:forgeVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)downloadOptiFine:(NSString *)gameVersion completion:(void (^)(BOOL success, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *optiFineVersion = [self mapGameVersionToOptiFine:gameVersion];
        if (!optiFineVersion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                !completion ?: completion(NO, [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"不支持的 OptiFine 版本"}]);
            });
            return;
        }
        
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/OptiFine_%@_%@.jar",
                                gameVersion, optiFineVersion, gameVersion, optiFineVersion];
        
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:downloadURL] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30];
        NSURLResponse *response = nil;
        NSError *downloadError = nil;
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&downloadError];
        
        if (!data || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                !completion ?: completion(NO, downloadError ?: [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"下载 OptiFine 失败"}]);
            });
            return;
        }
        
        NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
        const char *gameDirChar = getenv("POJAV_GAME_DIR");
        if (!gameDirChar) {
            dispatch_async(dispatch_get_main_queue(), ^{
                !completion ?: completion(NO, [NSError errorWithDomain:@"DownloadError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"游戏目录未配置"}]);
            });
            return;
        }
        
        NSString *gameDir = [NSString stringWithUTF8String:gameDirChar];
        NSString *profileDir = [gameDir stringByAppendingPathComponent:profileName];
        NSString *modsDir = [profileDir stringByAppendingPathComponent:@"mods"];
        
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *dirError;
        if (![fm createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                !completion ?: completion(NO, dirError);
            });
            return;
        }
        
        NSString *filename = [NSString stringWithFormat:@"OptiFine_%@_%@.jar", gameVersion, optiFineVersion];
        NSString *savePath = [modsDir stringByAppendingPathComponent:filename];
        
        NSError *saveError;
        BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&saveError];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            !completion ?: completion(success, saveError);
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

#pragma mark - NeoForge Installation
- (void)installNeoForge:(NSString *)gameVersion {
    ForgeInstallViewController *neoForgeVC = [[ForgeInstallViewController alloc] init];
    neoForgeVC.gameVersion = gameVersion;
    neoForgeVC.isNeoForge = YES;
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, NSError *) = ^(BOOL success, NSString *profileName, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (success) {
            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"NeoForge 安装成功\n配置文件: %@", profileName]];
        } else {
            [strongSelf showError:error.localizedDescription ?: @"NeoForge 安装失败"];
        }
    };
    neoForgeVC.completionHandler = completion;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:neoForgeVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装成功" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableView Delegate & DataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) {
        return self.modList.count + (self.hasMoreMods ? 1 : 0);
    } else if (tableView == self.shaderTableView) {
        return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 加载更多cell
    if ((tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) ||
        (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders)) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.backgroundColor = [UIColor clearColor];
        return cell;
    }
    
    // 修复button重复添加target-action问题
    if (tableView == self.modTableView) {
        ModernAssetCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
        NSDictionary *mod = self.modList[indexPath.row];
        [cell configureWithMod:mod];
        [cell.downloadButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [cell.downloadButton addTarget:self action:@selector(downloadMod:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
        return cell;
    } else {
        ModernAssetCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
        NSDictionary *shader = self.shaderList[indexPath.row];
        [cell configureWithShader:shader];
        [cell.downloadButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [cell.downloadButton addTarget:self action:@selector(downloadShader:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
        return cell;
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 修复分页越界问题
    if (tableView == self.modTableView) {
        NSInteger threshold = MAX(0, self.modList.count - 5);
        if (indexPath.row >= threshold && self.hasMoreMods && !self.isLoadingMore) {
            [self loadModList];
        }
    } else if (tableView == self.shaderTableView) {
        NSInteger threshold = MAX(0, self.shaderList.count - 5);
        if (indexPath.row >= threshold && self.hasMoreShaders && !self.isLoadingMore) {
            [self loadShaderList];
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // 加载更多点击
    if (tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) {
        [self loadModList];
        return;
    }
    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders) {
        [self loadShaderList];
        return;
    }
    
    // 正常点击
    if (tableView == self.modTableView) {
        [self downloadModAtIndexPath:indexPath];
    } else {
        [self downloadShaderAtIndexPath:indexPath];
    }
}

#pragma mark - Download Actions
// 修复原代码截断错误
- (void)downloadShader:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadShaderAtIndexPath:indexPath];
}

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
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:versionVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;
    
    NSDictionary *shader = self.shaderList[indexPath.row];
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:shader];
    
    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:versionVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - ModVersionViewControllerDelegate
- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    ModItem *itemToDownload = viewController.modItem;
    NSDictionary *primaryFile = version.primaryFile;
    
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }
    
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", itemToDownload.displayName];
    
    [viewController dismissViewControllerAnimated:YES completion:^{
        [self startDownloadForModItem:itemToDownload];
    }];
}

- (void)startDownloadForModItem:(ModItem *)item {
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载" message:item.displayName preferredStyle:UIAlertControllerStyleAlert];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:downloadingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:downloadingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    
    [self presentViewController:downloadingAlert animated:YES completion:nil];
    
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    [[ModService sharedService] downloadMod:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功" message:[NSString stringWithFormat:@"%@ 已安装", item.displayName] preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:successAlert animated:YES completion:nil];
                }
            }]);
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
    
    [viewController dismissViewControllerAnimated:YES completion:^{
        [self startDownloadForShaderItem:itemToDownload];
    }];
}

- (void)startDownloadForShaderItem:(ShaderItem *)item {
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载" message:item.displayName preferredStyle:UIAlertControllerStyleAlert];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:downloadingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:downloadingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    
    [self presentViewController:downloadingAlert animated:YES completion:nil];
    
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    __weak typeof(self) weakSelf = self;
    [[ShaderService sharedService] downloadShader:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功" message:[NSString stringWithFormat:@"%@ 已安装", item.displayName] preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:successAlert animated:YES completion:nil];
                }
            }]);
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
    if (context != (void *)kDownloadProgressKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    if (![keyPath isEqualToString:@"fractionCompleted"]) return;
    
    NSProgress *progress = self.downloadTask.progress;
    NSProgress *textProgress = self.downloadTask.textProgress;
    
    NSInteger completedUnitCount = progress.totalUnitCount * progress.fractionCompleted;
    textProgress.completedUnitCount = completedUnitCount;
    
    struct timeval tv;
    gettimeofday(&tv, NULL);
    
    if (self.lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        if (self.lastMsTime > 0) {
            NSInteger throughput = (completedUnitCount - self.lastCompletedUnitCount) / (currentTime - self.lastMsTime);
            textProgress.throughput = @(throughput);
            if (throughput > 0) {
                NSInteger remaining = (progress.totalUnitCount - completedUnitCount) / throughput;
                textProgress.estimatedTimeRemaining = @(remaining);
            }
        }
        self.lastCompletedUnitCount = completedUnitCount;
        self.lastSecTime = tv.tv_sec;
        self.lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressVC) return;
        
        if (self.downloadingAlert) {
            NSString *progressText = textProgress.localizedAdditionalDescription;
            if (!progressText.length) progressText = [NSString stringWithFormat:@"%.1f%%", progress.fractionCompleted * 100];
            
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
            
            self.downloadingAlert.message = [NSString stringWithFormat:@"正在下载...\n%@%@%@", progressText, speedText, etaText];
        }
        
        if (progress.finished || progress.cancelled) {
            [progress removeObserver:self forKeyPath:@"fractionCompleted" context:(void *)kDownloadProgressKVOContext];
            
            self.lastMsTime = 0;
            self.lastSecTime = 0;
            self.lastCompletedUnitCount = 0;
            
            self.view.userInteractionEnabled = YES;
            [self.loadingIndicator stopAnimating];
            
            if (self.downloadingAlert) {
                [self.dismissViewControllerAnimated:YES completion:nil];
                self.downloadingAlert = nil;
            }
            if (self.progressVC) {
                [self.progressVC dismissViewControllerAnimated:YES completion:nil];
                self.progressVC = nil;
            }
            
            if (progress.finished) {
                UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载完成" message:[NSString stringWithFormat:@"%@ 下载完成", self.downloadTask.metadata[@"id"] ?: @"版本"] preferredStyle:UIAlertControllerStyleAlert];
                [successAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:successAlert animated:YES completion:nil];
            }
            
            self.downloadTask = nil;
        }
    });
}

#pragma mark - Orientation
- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

@end