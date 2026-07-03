#import "DownloadViewController.h"
#import "BackgroundManager.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "PLPreferences.h"
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
#import "installer/ForgeDirectInstaller.h"
#import "installer/NeoForgeDirectInstaller.h"
#import "installer/NeoForgeVersionFetcher.h"
#import "LauncherNavigationController.h"
#import "installer/ModpackInstallViewController.h"
#import "ModpackImportViewController.h"
#import "installer/CurseForgeAPIKeyViewController.h"
#import "UZKArchive.h"
#import <QuartzCore/QuartzCore.h>
#import "JavaGUIViewController.h"
#import "utils.h"
#import "ALTServerConnection.h"

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

#pragma mark - Modern Asset Cell

@interface ModernAssetCell : UITableViewCell
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIStackView *tagsStack;
@property (nonatomic, strong) UIButton *downloadButton;
@end

@implementation ModernAssetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        
        self.contentContainer = [[UIView alloc] init];
        self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.contentContainer];
        
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 12;
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
        self.tagsStack.spacing = 6;
        self.tagsStack.distribution = UIStackViewDistributionFill;
        [self.contentContainer addSubview:self.tagsStack];
        
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        self.downloadButton.layer.cornerRadius = 20;
        [self.contentContainer addSubview:self.downloadButton];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.contentContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],
            [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:24],
            [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-24],
            [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],
            
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:56],
            [self.iconView.heightAnchor constraintEqualToConstant:56],
            
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
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
        
        [[BackgroundManager sharedManager] applyEffectToView:self.contentView];
    }
    return self;
}

- (void)configureWithMod:(NSDictionary *)mod {
    self.titleLabel.text = mod[@"title"] ?: mod[@"slug"] ?: @"Unknown";
    self.descLabel.text = mod[@"description"] ?: @"";
    
    NSString *author = mod[@"author"] ?: @"Unknown";
    NSNumber *downloads = mod[@"downloads"];
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
    
    NSString *iconUrl = mod[@"imageUrl"] ?: mod[@"icon_url"];
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.iconView.image = image;
                });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
        self.iconView.tintColor = [UIColor systemOrangeColor];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
    
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *categories = mod[@"categories"] ?: @[];
    for (NSInteger i = 0; i < MIN(3, categories.count); i++) {
        NSString *cat = categories[i];
        if ([cat isKindOfClass:[NSString class]]) {
            UILabel *tag = [self createTagLabel:cat];
            [self.tagsStack addArrangedSubview:tag];
        }
    }
}

- (void)configureWithShader:(NSDictionary *)shader {
    self.titleLabel.text = shader[@"title"] ?: shader[@"slug"] ?: @"Unknown";
    self.descLabel.text = shader[@"description"] ?: @"";
    
    NSString *author = shader[@"author"] ?: @"Unknown";
    NSNumber *downloads = shader[@"downloads"];
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
    
    NSString *iconUrl = shader[@"imageUrl"] ?: shader[@"icon_url"];
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.iconView.image = image;
                });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
        self.iconView.tintColor = [UIColor systemPurpleColor];
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
    
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *categories = shader[@"categories"] ?: @[];
    for (NSInteger i = 0; i < MIN(3, categories.count); i++) {
        NSString *cat = categories[i];
        if ([cat isKindOfClass:[NSString class]]) {
            UILabel *tag = [self createTagLabel:cat];
            [self.tagsStack addArrangedSubview:tag];
        }
    }
}

- (UILabel *)createTagLabel:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    label.textColor = [UIColor tertiaryLabelColor];
    label.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    label.layer.cornerRadius = 4;
    label.layer.masksToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    [label sizeToFit];
    CGRect frame = label.frame;
    frame.size.width += 8;
    frame.size.height = 18;
    label.frame = frame;
    return label;
}

@end

#pragma mark - Loader Selection Cell

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
        self.iconView.layer.cornerRadius = 10;
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
            [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            
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
    if (selected) {
        self.contentView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    } else {
        self.contentView.backgroundColor = [UIColor clearColor];
    }
}

- (void)setIncompatible:(BOOL)incompatible {
    if (incompatible) {
        self.statusLabel.hidden = NO;
        self.statusLabel.text = @"不兼容";
        self.statusLabel.textColor = [UIColor systemRedColor];
        self.nameLabel.textColor = [UIColor tertiaryLabelColor];
        self.descLabel.textColor = [UIColor quaternaryLabelColor];
        self.iconView.alpha = 0.5;
        self.userInteractionEnabled = NO;
    } else {
        self.statusLabel.hidden = YES;
        self.nameLabel.textColor = [UIColor labelColor];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.iconView.alpha = 1.0;
        self.userInteractionEnabled = YES;
    }
}

@end

#pragma mark - Loader Selection View Controller (居中卡片式)

@interface LoaderSelectionViewController : UIViewController
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion);
@property (nonatomic, copy) void (^cancelled)(void);
@property (nonatomic, strong) NSString *gameVersion;
@end

@interface LoaderSelectionViewController () <UITableViewDataSource, UITableViewDelegate, NSXMLParserDelegate>
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *optionsContainer;
@property (nonatomic, strong) UISwitch *fabricAPISwitch;
@property (nonatomic, strong) UISwitch *optiFineSwitch;
@property (nonatomic, strong) UILabel *fabricAPILabel;
@property (nonatomic, strong) UILabel *optiFineLabel;
@property (nonatomic, strong) UIButton *installButton;
@property (nonatomic, strong) NSString *selectedLoader;
@property (nonatomic, strong) NSArray *loaderVersions;
@property (nonatomic, strong) UITableView *versionTableView;
@property (nonatomic, strong) NSString *selectedLoaderVersion;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyVersionsLabel;

// For XML parsing
@property (nonatomic, strong) NSMutableArray *forgeVersionList;
@property (nonatomic, assign) BOOL isParsingForge;
@property (nonatomic, strong) NSMutableString *currentVersionValue;

// 网络任务取消
@property (nonatomic, strong) NSURLSessionDataTask *currentVersionTask;
@end

@implementation LoaderSelectionViewController

- (void)dealloc {
    if (self.currentVersionTask) {
        [self.currentVersionTask cancel];
        self.currentVersionTask = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor clearColor];
    self.preferredContentSize = CGSizeMake(540, 620);
    
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    
    [self setupNavigation];
    [self setupLoadersForVersion];
    [self setupLoaderTableView];
    [self setupOptionsContainer];
    [self setupInstallButton];
    [self setupVersionTableView];
}

- (void)setupLoadersForVersion {
    BOOL fabricCompatible = [self isFabricCompatible];
    BOOL quiltCompatible = [self isQuiltCompatible];
    BOOL forgeCompatible = [self isForgeCompatible];
    BOOL neoForgeCompatible = [self isNeoForgeCompatible];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor], @"compatible": @YES},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor], @"compatible": @(fabricCompatible)},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富（支持 1.1+）", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor], @"compatible": @(forgeCompatible)},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，支持 1.20.1+", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor], @"compatible": @(neoForgeCompatible)},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor], @"compatible": @(quiltCompatible)}
    ];
}

- (BOOL)isFabricCompatible {
    if (!self.gameVersion) return YES;
    NSArray *components = [self.gameVersion componentsSeparatedByString:@"."];
    if (components.count < 2) return YES;
    NSInteger major = [components[0] integerValue];
    NSInteger minor = [components[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 14) return YES;
    return NO;
}

- (BOOL)isQuiltCompatible {
    if (!self.gameVersion) return YES;
    NSArray *components = [self.gameVersion componentsSeparatedByString:@"."];
    if (components.count < 2) return YES;
    NSInteger major = [components[0] integerValue];
    NSInteger minor = [components[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 18) return YES;
    return NO;
}

- (BOOL)isForgeCompatible {
    if (!self.gameVersion) return YES;
    NSArray *components = [self.gameVersion componentsSeparatedByString:@"."];
    if (components.count < 2) return YES;
    NSInteger major = [components[0] integerValue];
    NSInteger minor = [components[1] integerValue];
    if (major == 1 && minor >= 1) return YES;
    if (major > 1) return YES;
    return NO;
}

- (BOOL)isNeoForgeCompatible {
    if (!self.gameVersion) return NO;
    NSArray *components = [self.gameVersion componentsSeparatedByString:@"."];
    if (components.count < 2) return NO;
    NSInteger major = [components[0] integerValue];
    NSInteger minor = [components[1] integerValue];
    NSInteger patch = (components.count > 2) ? [components[2] integerValue] : 0;
    if (major > 1) return YES;
    if (major == 1 && minor == 20 && patch >= 1) return YES;
    if (major == 1 && minor > 20) return YES;
    return NO;
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backButtonTapped)];
    self.navigationItem.leftBarButtonItem.tintColor = [UIColor labelColor];
}

- (void)backButtonTapped {
    if (self.cancelled) {
        self.cancelled();
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)setupLoaderTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 76;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[LoaderCell class] forCellReuseIdentifier:@"LoaderCell"];
    [self.view addSubview:self.tableView];
    
    UILayoutGuide *safeGuide;
    if (@available(iOS 11.0, *)) {
        safeGuide = self.view.safeAreaLayoutGuide;
    } else {
        safeGuide = self.view.layoutMarginsGuide;
    }
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:safeGuide.topAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.tableView.heightAnchor constraintEqualToConstant:320]
    ]];
}

- (void)setupOptionsContainer {
    self.optionsContainer = [[UIView alloc] init];
    self.optionsContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.optionsContainer.backgroundColor = [UIColor clearColor];
    
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
    
    self.optionsContainer.hidden = YES;
    [self.view addSubview:self.optionsContainer];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.optionsContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.optionsContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.optionsContainer.topAnchor constraintEqualToAnchor:self.tableView.bottomAnchor constant:8],
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
    
    self.emptyVersionsLabel = [[UILabel alloc] init];
    self.emptyVersionsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyVersionsLabel.text = @"暂无可用版本";
    self.emptyVersionsLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyVersionsLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyVersionsLabel.font = [UIFont systemFontOfSize:14];
    self.emptyVersionsLabel.hidden = YES;
    [self.view addSubview:self.emptyVersionsLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.versionTableView.topAnchor constraintEqualToAnchor:self.optionsContainer.bottomAnchor constant:8],
        [self.versionTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.versionTableView.bottomAnchor constraintEqualToAnchor:self.installButton.topAnchor constant:-16],
        
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.versionTableView.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.versionTableView.centerYAnchor],
        
        [self.emptyVersionsLabel.centerXAnchor constraintEqualToAnchor:self.versionTableView.centerXAnchor],
        [self.emptyVersionsLabel.centerYAnchor constraintEqualToAnchor:self.versionTableView.centerYAnchor]
    ]];
}

- (void)setupInstallButton {
    self.installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.installButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.installButton setTitle:@"安装" forState:UIControlStateNormal];
    self.installButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.installButton.backgroundColor = [UIColor systemGreenColor];
    [self.installButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.installButton.layer.cornerRadius = 10;
    [self.installButton addTarget:self action:@selector(installButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.installButton];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.installButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.installButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.installButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-20],
        [self.installButton.heightAnchor constraintEqualToConstant:50]
    ]];
}

- (void)installButtonTapped {
    if (!self.selectedLoader) {
        [self showAlert:@"请选择安装方式" message:nil];
        return;
    }
    
    BOOL needsVersion = ![self.selectedLoader isEqualToString:@"vanilla"];
    
    if (needsVersion) {
        if (self.loaderVersions == nil) {
            [self showAlert:@"正在加载版本列表" message:@"请稍后再试"];
            return;
        }
        if (self.loaderVersions.count == 0) {
            NSString *loaderName = @"";
            for (NSDictionary *loader in self.loaders) {
                if ([loader[@"id"] isEqualToString:self.selectedLoader]) {
                    loaderName = loader[@"name"];
                    break;
                }
            }
            [self showAlert:[NSString stringWithFormat:@"%@ 暂无可用的版本", loaderName]
                    message:[NSString stringWithFormat:@"当前选择的 Minecraft %@ 没有可用的 %@ 版本", self.gameVersion, loaderName]];
            return;
        }
        
        if (!self.selectedLoaderVersion) {
            [self showAlert:@"请选择版本" message:nil];
            return;
        }
    }
    
    BOOL installFabricAPI = [self.selectedLoader isEqualToString:@"fabric"] ? self.fabricAPISwitch.isOn : NO;
    BOOL installOptiFine = [self.selectedLoader isEqualToString:@"forge"] ? self.optiFineSwitch.isOn : NO;
    
    if (self.completion) {
        self.completion(self.selectedLoader, installFabricAPI, installOptiFine, self.selectedLoaderVersion);
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Load Versions (Real Network)

- (void)loadVersionsForLoader:(NSString *)loaderId {
    self.loaderVersions = nil;
    self.selectedLoaderVersion = nil;
    [self.versionTableView reloadData];
    self.versionTableView.hidden = NO;
    self.emptyVersionsLabel.hidden = YES;
    [self.loadingIndicator startAnimating];
    
    if (self.currentVersionTask) {
        [self.currentVersionTask cancel];
        self.currentVersionTask = nil;
    }
    
    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"quilt"]) {
        [self loadFabricVersions:loaderId];
    } else if ([loaderId isEqualToString:@"forge"]) {
        [self loadForgeVersionsReal];
    } else if ([loaderId isEqualToString:@"neoforge"]) {
        [self loadNeoForgeVersionsReal];
    }
}

- (void)loadFabricVersions:(NSString *)loaderType {
    NSString *urlString = [NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@", self.gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];
    
    __weak typeof(self) weakSelf = self;
    self.currentVersionTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            if (error && error.code != NSURLErrorCancelled) {
                strongSelf.loaderVersions = @[];
                [strongSelf.versionTableView reloadData];
                strongSelf.emptyVersionsLabel.hidden = NO;
                return;
            }
            if (data && !error) {
                NSError *jsonError;
                NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (versions && !jsonError) {
                    NSMutableArray *versionList = [NSMutableArray array];
                    for (NSDictionary *ver in versions) {
                        NSString *loaderVersion = ver[@"loader"][@"version"];
                        if (loaderVersion && ![versionList containsObject:loaderVersion]) {
                            [versionList addObject:loaderVersion];
                        }
                    }
                    strongSelf.loaderVersions = versionList;
                    [strongSelf.versionTableView reloadData];
                    strongSelf.emptyVersionsLabel.hidden = (versionList.count > 0);
                    if (versionList.count > 0 && !strongSelf.selectedLoaderVersion) {
                        strongSelf.selectedLoaderVersion = versionList[0];
                        [strongSelf.versionTableView reloadData];
                    }
                } else {
                    strongSelf.loaderVersions = @[];
                    [strongSelf.versionTableView reloadData];
                    strongSelf.emptyVersionsLabel.hidden = NO;
                }
            } else {
                strongSelf.loaderVersions = @[];
                [strongSelf.versionTableView reloadData];
                strongSelf.emptyVersionsLabel.hidden = NO;
            }
        });
    }];
    [self.currentVersionTask resume];
}

- (void)loadForgeVersionsReal {
    NSString *urlString = @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml";
    NSURL *url = [NSURL URLWithString:urlString];
    
    self.forgeVersionList = [NSMutableArray array];
    self.isParsingForge = YES;
    
    __weak typeof(self) weakSelf = self;
    self.currentVersionTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.loadingIndicator stopAnimating];
                strongSelf.loaderVersions = @[];
                [strongSelf.versionTableView reloadData];
                strongSelf.emptyVersionsLabel.hidden = NO;
            });
            return;
        }
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        parser.delegate = weakSelf;
        [parser parse];
    }];
    [self.currentVersionTask resume];
}

- (void)loadNeoForgeVersionsReal {
    __weak typeof(self) weakSelf = self;
    [NeoForgeVersionFetcher fetchVersionsForGameVersion:self.gameVersion completion:^(NSArray *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.loadingIndicator stopAnimating];
            strongSelf.loaderVersions = versions ?: @[];
            [strongSelf.versionTableView reloadData];
            strongSelf.emptyVersionsLabel.hidden = (strongSelf.loaderVersions.count > 0);
            if (strongSelf.loaderVersions.count > 0 && !strongSelf.selectedLoaderVersion) {
                strongSelf.selectedLoaderVersion = strongSelf.loaderVersions.firstObject;
                [strongSelf.versionTableView reloadData];
            }
        });
    }];
}

#pragma mark - NSXMLParserDelegate (Forge/NeoForge)

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"version"]) {
        self.currentVersionValue = [NSMutableString new];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.currentVersionValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (!self.isParsingForge) {
        return;
    }
    
    if ([elementName isEqualToString:@"version"]) {
        NSString *version = [self.currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.loadingIndicator stopAnimating];
        
        [self.forgeVersionList sortUsingComparator:^NSComparisonResult(NSString *v1, NSString *v2) {
            return [v2 compare:v1 options:NSNumericSearch];
        }];
        
        self.loaderVersions = self.forgeVersionList;
        [self.versionTableView reloadData];
        self.emptyVersionsLabel.hidden = (self.loaderVersions.count > 0);
        
        if (self.loaderVersions.count > 0 && !self.selectedLoaderVersion) {
            self.selectedLoaderVersion = self.loaderVersions.firstObject;
            [self.versionTableView reloadData];
        }
    });
}

- (void)parser:(NSXMLParser *)parser parseErrorOccurred:(NSError *)parseError {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.loadingIndicator stopAnimating];
        self.loaderVersions = @[];
        [self.versionTableView reloadData];
        self.emptyVersionsLabel.hidden = NO;
        NSLog(@"Parse error: %@", parseError);
    });
}


#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.tableView) {
        return self.loaders.count;
    } else if (tableView == self.versionTableView) {
        return self.loaderVersions.count;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.tableView) {
        LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
        NSDictionary *loader = self.loaders[indexPath.row];
        
        cell.nameLabel.text = loader[@"name"];
        cell.descLabel.text = loader[@"desc"];
        
        NSString *iconName = loader[@"icon"];
        UIImage *iconImage = [UIImage systemImageNamed:iconName];
        
        cell.iconView.image = iconImage;
        cell.iconView.tintColor = loader[@"color"];
        cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
        
        BOOL isSelected = [self.selectedLoader isEqualToString:loader[@"id"]];
        if (isSelected) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.tintColor = [UIColor systemGreenColor];
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        
        BOOL compatible = [loader[@"compatible"] boolValue];
        [cell setIncompatible:!compatible];
        
        return cell;
    } else {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell" forIndexPath:indexPath];
        NSString *version = self.loaderVersions[indexPath.row];
        cell.textLabel.text = version;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cell.backgroundColor = [UIColor clearColor];
        
        if ([self.selectedLoaderVersion isEqualToString:version]) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.tintColor = [UIColor systemGreenColor];
        } else {
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        
        return cell;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.tableView) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        
        NSDictionary *loader = self.loaders[indexPath.row];
        NSString *loaderId = loader[@"id"];
        
        BOOL compatible = [loader[@"compatible"] boolValue];
        if (!compatible) {
            return;
        }
        
        if ([self.selectedLoader isEqualToString:loaderId]) {
            self.selectedLoader = nil;
            self.optionsContainer.hidden = YES;
            self.versionTableView.hidden = YES;
        } else {
            self.selectedLoader = loaderId;
            self.optionsContainer.hidden = NO;
            self.optionsContainer.alpha = 0;
            
            [UIView animateWithDuration:0.3 animations:^{
                self.optionsContainer.alpha = 1;
            }];
            
            if ([loaderId isEqualToString:@"fabric"]) {
                self.fabricAPILabel.hidden = NO;
                self.fabricAPISwitch.hidden = NO;
                self.optiFineLabel.hidden = YES;
                self.optiFineSwitch.hidden = YES;
                [self loadVersionsForLoader:@"fabric"];
            } else if ([loaderId isEqualToString:@"forge"]) {
                self.fabricAPILabel.hidden = YES;
                self.fabricAPISwitch.hidden = YES;
                self.optiFineLabel.hidden = NO;
                self.optiFineSwitch.hidden = NO;
                [self loadVersionsForLoader:@"forge"];
            } else if ([loaderId isEqualToString:@"neoforge"]) {
                self.fabricAPILabel.hidden = YES;
                self.fabricAPISwitch.hidden = YES;
                self.optiFineLabel.hidden = YES;
                self.optiFineSwitch.hidden = YES;
                [self loadVersionsForLoader:@"neoforge"];
            } else if ([loaderId isEqualToString:@"quilt"]) {
                self.fabricAPILabel.hidden = YES;
                self.fabricAPISwitch.hidden = YES;
                self.optiFineLabel.hidden = YES;
                self.optiFineSwitch.hidden = YES;
                [self loadVersionsForLoader:@"quilt"];
            } else {
                self.fabricAPILabel.hidden = YES;
                self.fabricAPISwitch.hidden = YES;
                self.optiFineLabel.hidden = YES;
                self.optiFineSwitch.hidden = YES;
                self.versionTableView.hidden = YES;
            }
        }
        
        [tableView reloadData];
    } else if (tableView == self.versionTableView) {
        NSString *version = self.loaderVersions[indexPath.row];
        self.selectedLoaderVersion = version;
        [tableView reloadData];
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

// 当前待下载资源类型（mod/resourcepack/datapack），用于版本选择回调中决定下载目录
@property (nonatomic, copy) NSString *pendingDownloadType;

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
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];

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
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing = 10;
    layout.itemSize = CGSizeMake(100, 120);
    layout.sectionInset = UIEdgeInsetsMake(10, 10, 10, 10);
    
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
    self.shaderTableView.rowHeight = 100;
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
    self.modpackTableView.rowHeight = 100;
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
    self.resourcepackTableView.rowHeight = 100;
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
    self.datapackTableView.rowHeight = 100;
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
    self.worldTableView.rowHeight = 100;
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
        self.searchBar.hidden = (index == 0);
        self.filterButton.hidden = (index == 0);
        self.modTableView.hidden = (index != 1);
        self.shaderTableView.hidden = (index != 2);
        self.resourcepackTableView.hidden = (index != 3);
        self.datapackTableView.hidden = (index != 4);
        self.modpackTableView.hidden = (index != 5);
        self.worldTableView.hidden = (index != 6);
    } completion:nil];

    // 源切换仅在非版本 tab 显示
    BOOL showSourceSwitch = (index != 0);
    self.sourceSwitchContainer.hidden = !showSourceSwitch;
    self.sourceSwitchHeightConstraint.constant = showSourceSwitch ? 36 : 0;
    [UIView animateWithDuration:0.2 animations:^{
        [self.view layoutIfNeeded];
    }];

    if (index == 1) {
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

    // API Key 未配置时弹出引导提示，直接调用本 VC 的入口（不再走通知绕路）
    if (![PLPreferences curseForgeAPIKey] && ![[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要 CurseForge API Key"
                                                                       message:@"检测到未配置 CurseForge API Key，是否前往设置？"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"前往设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self openCurseForgeAPIKeySettings];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    [PLPreferences setDownloadSource:@"curseforge" forType:type];
    [self updateSourceSwitchButtonsForType:type];
    [self reloadCurrentList];
}

- (id)currentAPIForTabType:(NSString *)type {
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
    NSMutableArray *filtered = [NSMutableArray array];
    
    for (NSDictionary *version in self.versionList) {
        NSString *type = version[@"type"];
        
        if (filterIndex == 0) {
            [filtered addObject:version];
        } else if (filterIndex == 1 && [type isEqualToString:@"release"]) {
            [filtered addObject:version];
        } else if (filterIndex == 2 && [type isEqualToString:@"snapshot"]) {
            [filtered addObject:version];
        } else if (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"])) {
            [filtered addObject:version];
        }
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
    
    self.emptyLabel.hidden = (self.filteredVersions.count > 0);
    if (self.filteredVersions.count == 0) {
        self.emptyLabel.text = @"暂无版本";
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];

    NSInteger tabIndex = self.tabSegment.selectedSegmentIndex;
    if (tabIndex == 1) {
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
    [searchBar resignFirstResponder];
    [self reloadCurrentList];
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
    
    return cell;
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

#pragma mark - Loader Selection (居中卡片)

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    LoaderSelectionViewController *loaderVC = [[LoaderSelectionViewController alloc] init];
    loaderVC.gameVersion = version[@"id"];
    
    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI, BOOL installOptiFine, NSString *loaderVersion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        [strongSelf dismissViewControllerAnimated:YES completion:^{
            [strongSelf proceedWithVersion:version loaderType:loaderType installFabricAPI:installFabricAPI installOptiFine:installOptiFine loaderVersion:loaderVersion];
        }];
    };
    
    loaderVC.cancelled = ^{
        // 用户取消
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loaderVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    nav.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    
    [self presentViewController:nav animated:YES completion:nil];
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
    
    self.downloadingAlert = [UIAlertController alertControllerWithTitle:@"下载中"
                                                                message:@"正在准备下载..."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *detailsAction = [UIAlertAction actionWithTitle:@"查看详情"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction * _Nonnull action) {
        if (weakSelf.downloadTask) {
            weakSelf.progressVC = [[DownloadProgressViewController alloc] initWithTask:weakSelf.downloadTask];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:weakSelf.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [weakSelf presentViewController:nav animated:YES completion:nil];
        }
    }];
    [self.downloadingAlert addAction:detailsAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                           style:UIAlertActionStyleDestructive
                                                         handler:^(UIAlertAction * _Nonnull action) {
        if (weakSelf.downloadTask) {
            if (weakSelf.isObservingProgress) {
                [weakSelf.downloadTask.progress removeObserver:weakSelf forKeyPath:@"fractionCompleted"];
                weakSelf.isObservingProgress = NO;
            }
            [weakSelf.downloadTask.progress cancel];
            weakSelf.downloadTask = nil;
        }
        weakSelf.view.userInteractionEnabled = YES;
        [weakSelf.loadingIndicator stopAnimating];
        [weakSelf.downloadingAlert dismissViewControllerAnimated:YES completion:nil];
        weakSelf.downloadingAlert = nil;
    }];
    [self.downloadingAlert addAction:cancelAction];
    
    [self presentViewController:self.downloadingAlert animated:YES completion:nil];
    [self.loadingIndicator startAnimating];
    
    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;
    
    self.downloadTask.retryCallback = ^(NSInteger retryCount, NSInteger maxRetryCount) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.downloadingAlert) {
                weakSelf.downloadingAlert.message = [NSString stringWithFormat:@"下载失败，正在重试 (%ld/%ld)...", (long)retryCount, (long)maxRetryCount];
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
            weakSelf.downloadTask = nil;
            weakSelf.progressVC = nil;
            weakSelf.downloadingAlert = nil;
            
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
            NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];
            
            [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            
            NSError *saveError;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:NSJSONWritingPrettyPrinted error:&saveError];
            [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError];
            
            if (saveError) {
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
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
                                                                   message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载完成"
                                                                        message:message
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:alert animated:YES completion:nil];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:launchInstaller];
        });
    };
    
    if (self.presentedViewController) {
        [self dismissViewControllerAnimated:YES completion:showAlertAndLaunch];
    } else {
        showAlertAndLaunch();
    }
}

- (void)installForge:(NSString *)gameVersion installOptiFine:(BOOL)installOptiFine {
    ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
    forgeVC.gameVersion = gameVersion;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (!success) {
            [strongSelf handleInstallerDownloadResultWithVendorName:@"Forge"
                                                        gameVersion:gameVersion
                                                        profileName:profileName
                                                      resultOrError:resultOrError
                                                       installAction:nil];
            return;
        }

        // 解析 ForgeInstallViewController 打包的回调结果
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        if (selectedScheme == 1 && filePath.length > 0) {
            // Direct install scheme
            NSLog(@"[ForgeDirect] DownloadViewController: starting direct install with progress UI");

            // 创建进度 alert（在主线程创建并显示），含进度条和阶段文案
            UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"Forge 直装中"
                                                                                  message:@"准备中..."
                                                                           preferredStyle:UIAlertControllerStyleAlert];

            // 通过 KVC 获取 contentViewController，添加 UIProgressView 进度条
            UIViewController *contentVC = [progressAlert valueForKey:@"contentViewController"];
            UIProgressView *progressBar = nil;
            UILabel *stageLabel = nil;
            if (contentVC) {
                UIView *containerView = contentVC.view;
                progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                progressBar.progress = 0.0;
                progressBar.translatesAutoresizingMaskIntoConstraints = NO;
                [containerView addSubview:progressBar];

                stageLabel = [[UILabel alloc] init];
                stageLabel.text = @"准备中...";
                stageLabel.textAlignment = NSTextAlignmentCenter;
                stageLabel.font = [UIFont systemFontOfSize:13];
                stageLabel.numberOfLines = 0;
                stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
                [containerView addSubview:stageLabel];

                [NSLayoutConstraint activateConstraints:@[
                    [stageLabel.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:8],
                    [stageLabel.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:12],
                    [stageLabel.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-12],
                    [progressBar.topAnchor constraintEqualToAnchor:stageLabel.bottomAnchor constant:8],
                    [progressBar.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:12],
                    [progressBar.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-12],
                    [progressBar.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8]
                ]];
            }

            __block UIProgressView *blockProgressBar = progressBar;
            __block UILabel *blockStageLabel = stageLabel;

            [strongSelf presentViewController:progressAlert animated:YES completion:nil];

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *directError = nil;
                BOOL installed = [ForgeDirectInstaller installForgeFromInstaller:filePath
                                                                       versionId:profileName
                                                                         progress:^(double progress, NSString *stageMessage) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // 更新进度条和阶段文案
                        NSString *message = [NSString stringWithFormat:@"%@ - %.0f%%", stageMessage ?: @"", progress * 100];
                        progressAlert.message = message;
                        if (blockStageLabel) {
                            blockStageLabel.text = message;
                        }
                        if (blockProgressBar) {
                            [blockProgressBar setProgress:(float)progress animated:YES];
                        }
                    });
                }
                                                                           error:&directError];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [progressAlert dismissViewControllerAnimated:YES completion:^{
                        __strong typeof(weakSelf) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (installed) {
                            [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"Forge 直装成功\n配置文件: %@", profileName ?: gameVersion]];
                        } else {
                            [strongSelf2 showError:[NSString stringWithFormat:@"Forge 直装失败: %@", directError.localizedDescription ?: @"未知错误"]];
                        }
                    }];
                });
            });
            return;
        }

        // Original scheme (run installer)
        [strongSelf handleInstallerDownloadResultWithVendorName:@"Forge"
                                                    gameVersion:gameVersion
                                                    profileName:profileName
                                                  resultOrError:resultOrError
                                                   installAction:^{
            if (installOptiFine) {
                [strongSelf downloadOptiFine:gameVersion completion:^(BOOL optiSuccess, NSError *optiError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (optiSuccess) {
                            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Forge 安装器已启动\nOptiFine 已自动安装\n配置文件: %@", profileName ?: gameVersion]];
                        } else {
                            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Forge 安装器已启动\nOptiFine 安装失败: %@\n配置文件: %@", optiError.localizedDescription ?: @"未知错误", profileName ?: gameVersion]];
                        }
                    });
                }];
            } else {
                [strongSelf showSuccessMessage:[NSString stringWithFormat:@"Forge 安装器已启动\n配置文件: %@", profileName ?: gameVersion]];
            }
        }];
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
                if (completion) completion(NO, [NSError errorWithDomain:@"DownloadError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"不支持的 OptiFine 版本"}]);
            });
            return;
        }
        
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/OptiFine_%@_%@.jar",
                                gameVersion, optiFineVersion, gameVersion, optiFineVersion];
        
        NSURL *url = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&downloadError];
        
        if (!data || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, downloadError ?: [NSError errorWithDomain:@"DownloadError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"下载 OptiFine 失败"}]);
            });
            return;
        }
        
        NSString *modsDir = [self currentInstanceModsPath];
        NSString *filename = [NSString stringWithFormat:@"OptiFine_%@_%@.jar", gameVersion, optiFineVersion];
        NSString *savePath = [modsDir stringByAppendingPathComponent:filename];
        
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

#pragma mark - NeoForge Installation

- (void)installNeoForge:(NSString *)gameVersion {
    ForgeInstallViewController *neoForgeVC = [[ForgeInstallViewController alloc] init];
    neoForgeVC.gameVersion = gameVersion;
    neoForgeVC.isNeoForge = YES;

    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, id) = ^(BOOL success, NSString *profileName, id resultOrError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (!success) {
            [strongSelf handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                        gameVersion:gameVersion
                                                        profileName:profileName
                                                      resultOrError:resultOrError
                                                       installAction:nil];
            return;
        }

        // 解析 ForgeInstallViewController 打包的回调结果
        NSInteger selectedScheme = 0;
        NSString *filePath = nil;
        if ([resultOrError isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = (NSDictionary *)resultOrError;
            filePath = result[@"filePath"];
            selectedScheme = [result[@"selectedScheme"] integerValue];
        } else if ([resultOrError isKindOfClass:[NSString class]]) {
            filePath = (NSString *)resultOrError;
        }

        if (selectedScheme == 1 && filePath.length > 0) {
            // 直装方案
            NSLog(@"[NeoForgeDirect] DownloadViewController: starting direct install with progress UI");

            UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"NeoForge 直装中"
                                                                                  message:@"准备中..."
                                                                           preferredStyle:UIAlertControllerStyleAlert];

            UIViewController *contentVC = [progressAlert valueForKey:@"contentViewController"];
            UIProgressView *progressBar = nil;
            UILabel *stageLabel = nil;
            if (contentVC) {
                UIView *containerView = contentVC.view;
                progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
                progressBar.progress = 0.0;
                progressBar.translatesAutoresizingMaskIntoConstraints = NO;
                [containerView addSubview:progressBar];

                stageLabel = [[UILabel alloc] init];
                stageLabel.text = @"准备中...";
                stageLabel.textAlignment = NSTextAlignmentCenter;
                stageLabel.font = [UIFont systemFontOfSize:13];
                stageLabel.numberOfLines = 0;
                stageLabel.translatesAutoresizingMaskIntoConstraints = NO;
                [containerView addSubview:stageLabel];

                [NSLayoutConstraint activateConstraints:@[
                    [stageLabel.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:8],
                    [stageLabel.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:12],
                    [stageLabel.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-12],
                    [progressBar.topAnchor constraintEqualToAnchor:stageLabel.bottomAnchor constant:8],
                    [progressBar.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:12],
                    [progressBar.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-12],
                    [progressBar.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8]
                ]];
            }

            __block UIProgressView *blockProgressBar = progressBar;
            __block UILabel *blockStageLabel = stageLabel;

            [strongSelf presentViewController:progressAlert animated:YES completion:nil];

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *directError = nil;
                BOOL installed = [NeoForgeDirectInstaller installNeoForgeFromInstaller:filePath
                                                                               versionId:profileName
                                                                                progress:^(double progress, NSString *stageMessage) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSString *message = [NSString stringWithFormat:@"%@ - %.0f%%", stageMessage ?: @"", progress * 100];
                        progressAlert.message = message;
                        if (blockStageLabel) {
                            blockStageLabel.text = message;
                        }
                        if (blockProgressBar) {
                            [blockProgressBar setProgress:(float)progress animated:YES];
                        }
                    });
                }
                                                                                   error:&directError];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [progressAlert dismissViewControllerAnimated:YES completion:^{
                        __strong typeof(weakSelf) strongSelf2 = weakSelf;
                        if (!strongSelf2) return;
                        if (installed) {
                            [strongSelf2 showSuccessMessage:[NSString stringWithFormat:@"NeoForge 直装成功\n配置文件: %@", profileName ?: gameVersion]];
                        } else {
                            [strongSelf2 showError:[NSString stringWithFormat:@"NeoForge 直装失败: %@", directError.localizedDescription ?: @"未知错误"]];
                        }
                    }];
                });
            });
            return;
        }

        // 原版方案（运行安装器）
        [strongSelf handleInstallerDownloadResultWithVendorName:@"NeoForge"
                                                    gameVersion:gameVersion
                                                    profileName:profileName
                                                  resultOrError:resultOrError
                                                   installAction:^{
            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"NeoForge 安装器已启动\n配置文件: %@", profileName ?: gameVersion]];
        }];
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
    ModpackImportViewController *importVC = [[ModpackImportViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:importVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)installModpack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self installModpackAtIndexPath:indexPath];
}

- (void)installModpackAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *modpack = self.modpackList[indexPath.row];
    id api = [self currentAPIForTabType:@"modpack"];
    [api getVersionsForModWithID:modpack[@"id"] completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || versions.count == 0) {
                [self showError:@"获取整合包版本失败"];
                return;
            }
            [self showModpackVersionSelection:versions modpack:modpack];
        });
    }];
}

- (void)showModpackVersionSelection:(NSArray<ModVersion *> *)versions modpack:(NSDictionary *)modpack {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择整合包版本" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (ModVersion *ver in versions) {
        NSString *title = ver.name;
        if (ver.gameVersions.count > 0) {
            title = [NSString stringWithFormat:@"%@ - %@", ver.name, ver.gameVersions.firstObject];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self startModpackInstallation:ver modpack:modpack];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startModpackInstallation:(ModVersion *)version modpack:(NSDictionary *)modpack {
    NSString *downloadURL = version.primaryFile[@"url"];
    if (!downloadURL) {
        [self showError:@"无效的下载链接"];
        return;
    }
    
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"正在下载整合包" message:@"0%" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progressAlert animated:YES completion:nil];
    
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:downloadURL] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [self showError:error.localizedDescription];
                    return;
                }
                NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mrpack", modpack[@"id"]]];
                [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
                [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:tempPath error:nil];
                [self installModpackFromFile:tempPath modpack:modpack];
            }];
        });
    }];
    [task resume];
}

- (void)installModpackFromFile:(NSString *)filePath modpack:(NSDictionary *)modpack {
    MinecraftResourceDownloadTask *downloader = [[MinecraftResourceDownloadTask alloc] init];
    NSString *destPath = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), modpack[@"id"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    id api = [self currentAPIForTabType:@"modpack"];
    [api downloader:downloader submitDownloadTasksFromPackage:filePath toPath:destPath];
    
    self.progressVC = [[DownloadProgressViewController alloc] initWithTask:downloader];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
    
    __weak typeof(self) weakSelf = self;
    downloader.modpackDownloadCompletion = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.progressVC dismissViewControllerAnimated:YES completion:nil];
            [weakSelf showSuccessMessage:[NSString stringWithFormat:@"整合包 %@ 安装完成", modpack[@"title"]]];
        });
    };
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
        [cell configureWithMod:resourcepack];
        [cell.downloadButton addTarget:self action:@selector(downloadResourcepack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.datapackTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"DatapackCell" forIndexPath:indexPath];
        NSDictionary *datapack = self.datapackList[indexPath.row];
        [cell configureWithMod:datapack];
        [cell.downloadButton addTarget:self action:@selector(downloadDatapack:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else if (tableView == self.worldTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"WorldCell" forIndexPath:indexPath];
        NSDictionary *world = self.worldList[indexPath.row];
        [cell configureWithMod:world];
        [cell.downloadButton addTarget:self action:@selector(downloadWorld:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell" forIndexPath:indexPath];
        NSDictionary *modpack = self.modpackList[indexPath.row];
        [cell configureWithMod:modpack];
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
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:resourcepack];

    self.pendingDownloadType = @"resourcepack";

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadDatapack:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadDatapackAtIndexPath:indexPath];
}

- (void)downloadDatapackAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.datapackList.count) return;

    NSDictionary *datapack = self.datapackList[indexPath.row];
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:datapack];

    self.pendingDownloadType = @"datapack";

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;

    [self.navigationController pushViewController:versionVC animated:YES];
}

- (void)downloadWorld:(UIButton *)sender {
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:sender.tag inSection:0];
    [self downloadWorldAtIndexPath:indexPath];
}

- (void)downloadWorldAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.worldList.count) return;

    NSDictionary *world = self.worldList[indexPath.row];
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:world];

    self.pendingDownloadType = @"world";

    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    versionVC.title = modItem.displayName;

    [self.navigationController pushViewController:versionVC animated:YES];
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

    NSString *downloadType = self.pendingDownloadType ?: @"mod";
    self.pendingDownloadType = nil;

    // 子页面已 push 到导航栈，选完版本后 pop 回下载列表
    [self.navigationController popViewControllerAnimated:YES];
    if ([downloadType isEqualToString:@"resourcepack"] || [downloadType isEqualToString:@"datapack"]) {
        [self startDownloadForAssetItem:itemToDownload type:downloadType];
    } else if ([downloadType isEqualToString:@"world"]) {
        [self startDownloadForWorldItem:itemToDownload];
    } else {
        [self startDownloadForModItem:itemToDownload];
    }
}

- (void)startDownloadForModItem:(ModItem *)item {
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                              message:item.displayName
                                                                       preferredStyle:UIAlertControllerStyleAlert];

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
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已安装", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:successAlert animated:YES completion:nil];
                }
            }];
        });
    }];
}

- (void)startDownloadForAssetItem:(ModItem *)item type:(NSString *)type {
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                              message:item.displayName
                                                                       preferredStyle:UIAlertControllerStyleAlert];

    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:downloadingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:downloadingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];

    [self presentViewController:downloadingAlert animated:YES completion:nil];

    // 目标目录：resourcepacks / datapacks
    NSString *folderName = [type isEqualToString:@"datapack"] ? @"datapacks" : @"resourcepacks";
    NSString *baseDir;
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        baseDir = [NSString stringWithUTF8String:env];
    } else {
        baseDir = NSHomeDirectory();
    }

    NSString *profileName = PLProfiles.current.selectedProfileName;
    if (profileName.length > 0) {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profileName];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
                if ([gameDir isAbsolutePath]) {
                    baseDir = gameDir;
                } else {
                    baseDir = [baseDir stringByAppendingPathComponent:gameDir];
                }
            }
        }
    }

    NSString *destDir = [baseDir stringByAppendingPathComponent:folderName];
    [[NSFileManager defaultManager] createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *destPath = [destDir stringByAppendingPathComponent:item.fileName ?: [NSString stringWithFormat:@"%@.zip", item.displayName]];

    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        __weak typeof(self) weakSelf = self;
        [downloadingAlert dismissViewControllerAnimated:YES completion:^{
            [weakSelf showError:@"无效的下载链接"];
        }];
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                    return;
                }
                [[NSFileManager defaultManager] removeItemAtPath:destPath error:nil];
                NSError *moveError = nil;
                [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:destPath error:&moveError];
                if (moveError) {
                    [strongSelf showError:moveError.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已安装到 %@", item.displayName, folderName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:successAlert animated:YES completion:nil];
                }
            }];
        });
    }];
    [task resume];
}

// 下载世界存档并解压到 saves 目录（仿 FCL 安卓世界下载行为）
- (void)startDownloadForWorldItem:(ModItem *)item {
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                              message:item.displayName
                                                                       preferredStyle:UIAlertControllerStyleAlert];

    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [downloadingAlert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:downloadingAlert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:downloadingAlert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];

    [self presentViewController:downloadingAlert animated:YES completion:nil];

    // 目标目录：saves
    NSString *baseDir;
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        baseDir = [NSString stringWithUTF8String:env];
    } else {
        baseDir = NSHomeDirectory();
    }

    NSString *profileName = PLProfiles.current.selectedProfileName;
    if (profileName.length > 0) {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profileName];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
                if ([gameDir isAbsolutePath]) {
                    baseDir = gameDir;
                } else {
                    baseDir = [baseDir stringByAppendingPathComponent:gameDir];
                }
            }
        }
    }

    NSString *savesDir = [baseDir stringByAppendingPathComponent:@"saves"];
    [[NSFileManager defaultManager] createDirectoryAtPath:savesDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        __weak typeof(self) weakSelf = self;
        [downloadingAlert dismissViewControllerAnimated:YES completion:^{
            [weakSelf showError:@"无效的下载链接"];
        }];
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                    return;
                }
                // 世界存档为 zip，先下载到临时文件再解压到 saves 目录
                NSString *tempZip = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"world_%@.zip", @(arc4random())]];
                NSError *moveError = nil;
                [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:tempZip error:&moveError];
                if (moveError) {
                    [strongSelf showError:moveError.localizedDescription];
                    return;
                }
                // 解压 zip 到 saves 目录
                NSError *unzipError = nil;
                UZKArchive *archive = [[UZKArchive alloc] initWithPath:tempZip error:&unzipError];
                if (unzipError) {
                    [strongSelf showError:unzipError.localizedDescription];
                    [[NSFileManager defaultManager] removeItemAtPath:tempZip error:nil];
                    return;
                }
                BOOL extracted = [archive extractFilesTo:savesDir overwrite:NO error:&unzipError];
                [[NSFileManager defaultManager] removeItemAtPath:tempZip error:nil];
                if (!extracted || unzipError) {
                    [strongSelf showError:unzipError.localizedDescription ?: @"解压失败"];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已解压到 saves 目录", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:successAlert animated:YES completion:nil];
                }
            }];
        });
    }];
    [task resume];
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
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                              message:item.displayName
                                                                       preferredStyle:UIAlertControllerStyleAlert];
    
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
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已安装", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:successAlert animated:YES completion:nil];
                }
            }];
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
            
            self.downloadingAlert.message = [NSString stringWithFormat:@"正在下载...\n%@%@%@", progressText, speedText, etaText];
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
                [self dismissViewControllerAnimated:YES completion:nil];
                self.downloadingAlert = nil;
            }
            
            if (self.progressVC) {
                [self.progressVC dismissViewControllerAnimated:YES completion:nil];
                self.progressVC = nil;
            }
            
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载完成"
                                                                                  message:[NSString stringWithFormat:@"%@ 下载完成", self.downloadTask.metadata[@"id"] ?: @"版本"]
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:successAlert animated:YES completion:nil];
            
            self.downloadTask = nil;
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