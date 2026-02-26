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
#import "FabricInstallViewController.h"
#import "ForgeInstallViewController.h"
#import <QuartzCore/QuartzCore.h>
#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

#pragma mark - Reusable Cell Classes

@interface ModernAssetCell : UITableViewCell
@property (nonatomic, strong) UIVisualEffectView *blurView;
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
    if (!self) return nil;
    
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor clearColor];
    
    [self setupBlurView];
    [self setupContentContainer];
    [self setupIconView];
    [self setupLabels];
    [self setupTagsStack];
    [self setupDownloadButton];
    [self setupConstraints];
    
    return self;
}

- (void)setupBlurView {
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
    self.blurView.layer.cornerRadius = 16;
    self.blurView.layer.masksToBounds = YES;
    self.blurView.layer.borderWidth = 0.5;
    self.blurView.layer.borderColor = [UIColor separatorColor].CGColor;
    [self.contentView addSubview:self.blurView];
}

- (void)setupContentContainer {
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.blurView.contentView addSubview:self.contentContainer];
}

- (void)setupIconView {
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.layer.cornerRadius = 12;
    self.iconView.clipsToBounds = YES;
    self.iconView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.iconView.contentMode = UIViewContentModeScaleAspectFill;
    [self.contentContainer addSubview:self.iconView];
}

- (void)setupLabels {
    self.titleLabel = [self createLabelWithFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] color:[UIColor labelColor] lines:1];
    self.descLabel = [self createLabelWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption1] color:[UIColor secondaryLabelColor] lines:2];
    self.metaLabel = [self createLabelWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleCaption2] color:[UIColor tertiaryLabelColor] lines:1];
}

- (UILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    self.descLabelUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 100;
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    [tv registerClass:[ModernAssetCell class] forCellReuseIdentifier:identifier];
    tv.hidden = YES;
    
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:(type == 1 ? @selector(refreshModList) : @selector(refreshShaderList)) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = refresh;
    
    [self.view addSubview:tv];
    
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    if (type == 1) self.modTableView = tv;
    else self.shaderTableView = tv;
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
    self.emptyLabel.font = [UIFont preferredFontForTextUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 100;
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    [tv registerClass:[ModernAssetCell class] forCellReuseIdentifier:identifier];
    tv.hidden = YES;
    
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:(type == 1 ? @selector(refreshModList) : @selector(refreshShaderList)) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = refresh;
    
    [self.view addSubview:tv];
    
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    if (type == 1) self.modTableView = tv;
    else self.shaderTableView = tv;
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

#pragma mark - Tab & Data Loading

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
    
    if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        if (self.modList.count == 0) [self loadModList];
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        if (self.shaderList.count == 0) [self loadShaderList];
    }
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *urlString = [downloadSource isEqualToString:@"bmclapi"] ?
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" :
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyVersionFilter];
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
        BOOL shouldInclude = (filterIndex == 0) ||
                            (filterIndex == 1 && [type isEqualToString:@"release"]) ||
                            (filterIndex == 2 && [type isEqualToString:@"snapshot"]) ||
                            (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]));
        if (shouldInclude) [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
}

#pragma mark - Mod & Shader Loading

- (void)loadListWithType:(NSInteger)type {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    BOOL isMod =UILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 100;
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    [tv registerClass:[ModernAssetCell class] forCellReuseIdentifier:identifier];
    tv.hidden = YES;
    
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:(type == 1 ? @selector(refreshModList) : @selector(refreshShaderList)) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = refresh;
    
    [self.view addSubview:tv];
    
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    if (type == 1) self.modTableView = tv;
    else self.shaderTableView = tv;
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

#pragma mark - Tab & Data Loading

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
    
    if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        if (self.modList.count == 0) [self loadModList];
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        if (self.shaderList.count == 0) [self loadShaderList];
    }
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *urlString = [downloadSource isEqualToString:@"bmclapi"] ?
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" :
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyVersionFilter];
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
        BOOL shouldInclude = (filterIndex == 0) ||
                            (filterIndex == 1 && [type isEqualToString:@"release"]) ||
                            (filterIndex == 2 && [type isEqualToString:@"snapshot"]) ||
                            (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]));
        if (shouldInclude) [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
}

#pragma mark - Mod & Shader Loading

- (void)loadListWithType:(NSInteger)type {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    BOOL isMod = (type == 1);
    NSInteger offset = isMod ? self.currentModOffset : self.currentShaderOffset;
    
    if (offset == 0) [self.loadingIndicator startAnimating];
    
    NSMutableDictionary *filters = [@{@"limit": @30, @"offset": @(offset)} mutableCopy];
    if (self.currentSearchQuery.length > 0) filters[@"query"] = self.currentSearchQuery;
    if (self.currentGameVersion.length > 0) filters[@"version"] = self.currentGameVersion;
    
    void (^completion)(NSArray *, NSError *) = ^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            UITableView *tableView = isMod ? self.modTableView : self.shaderTableView;
            [tableView.refreshControl endRefreshing];
            self.isLoadingMore = NO;
            
            NSMutableArray *list = isMod ? self.modList : self.shaderList;
            BOOL *hasMore = isMod ? &self->_hasMoreMods : &self->_hasMoreShaders;
            NSInteger *currentOffset = isMod ? &self->_currentModOffset : &self->_currentShaderOffset;
            
            if (results) {
                if (offset == 0) [list removeAllObjects];
                [list addObjectsFromArray:results];
                *hasMore = (results.count >= 30);
                *currentOffset += results.count;
                [tableView reloadData];
                self.emptyLabel.hidden = (list.count > 0);
            } else if (error) {
                [self showError:error.localizedDescription];
            }
        });
    };
    
    if (isMod) {
        [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:completion];
    } else {
        [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:completion];
    }
}

- (void)refreshModList {
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self loadListWithType:1];
}

- (void)loadModList {
    [self loadListWithType:1];
}

- (void)searchMods:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

- (void)refreshShaderList {
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self loadListWithType:2];
}

- (void)loadShaderList {
    [self loadListWithType:2];
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"选择游戏版本" items:@[@"全部版本", @"1.21", @"1.20.4", @"1.20.1", @"1.19.4", @"1.19.2", @"1.18.2", @"1.16.5", @"1.12.2", @"1.8.9"] handler:^(NSString *selected) {
            self.currentGameVersion = [selected isEqualToString:@"全部版本"] ? nil : selected;
            [self reloadCurrentList];
        }];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"排序方式" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"排序方式" items:@[@"关注度", @"下载数", @"最近更新", @"最新发布", @"相关性"] handler:^(NSString *selected) {
            NSDictionary *map = @{@"关注度": @"follows", @"下载数": @"downloads", @"最近更新": @"updated", @"最新发布": @"newest", @"相关性": @"relevance"};
            self.currentSortField = map[selected];
            [self reloadCurrentList];
        }];
    }]];
    
    if (tabIndex == 1) {
        [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self showPickerWithTitle:@"模组加载器" items:@[@"全部", @"Fabric", @"Forge", @"Quilt", @"NeoForge"] handler:^(NSString *selected) {
                NSDictionary *map = @{@"全部": [NSNull null], @"Fabric": @"fabric", @"Forge": @"forge", @"Quilt": @"quilt", @"NeoForge": @"neoforge"};
                id value = map[selected];
                self.currentModLoader = (value == [NSNull null]) ? nil : value;
                [self reloadCurrentList];
            }];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { [self resetFilters]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)showPickerWithTitle:(NSString *)title items:(NSArray *)items handler:(void (^)(NSString *))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *item in items) {
        [alert addAction:[UIAlertAction actionWithTitle:item style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { handler(item); }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)presentAlert:(UIAlertController *)alert fromView:(UIView *)sourceView {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
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

#pragma mark - Search Delegate

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

#pragma mark - CollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *date = [version[@"releaseTime"] length] >= 10 ? [version[@"releaseTime"] substringToIndex:10] : version[@"releaseTime"];
    [cell configureWithVersionId:version[@"id"] date:date type:version[@"type"]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self showLoaderSelectionForVersion:self.filteredVersions[indexPath.row]];
}

#pragma mark - Loader Selection

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    LoaderSelectionViewController *loaderVC = [[LoaderSelectionViewController alloc] init];
    
    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf proceedWithVersion:version loaderType:loaderType installFabricAPI:installFabricAPI];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loaderVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.preferredContentSize = CGSizeMake(400, 500);
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI {
    NSString *versionId = versionUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 100;
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    [tv registerClass:[ModernAssetCell class] forCellReuseIdentifier:identifier];
    tv.hidden = YES;
    
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:(type == 1 ? @selector(refreshModList) : @selector(refreshShaderList)) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = refresh;
    
    [self.view addSubview:tv];
    
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    if (type == 1) self.modTableView = tv;
    else self.shaderTableView = tv;
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

#pragma mark - Tab & Data Loading

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
    
    if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        if (self.modList.count == 0) [self loadModList];
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        if (self.shaderList.count == 0) [self loadShaderList];
    }
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *urlString = [downloadSource isEqualToString:@"bmclapi"] ?
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" :
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyVersionFilter];
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
        BOOL shouldInclude = (filterIndex == 0) ||
                            (filterIndex == 1 && [type isEqualToString:@"release"]) ||
                            (filterIndex == 2 && [type isEqualToString:@"snapshot"]) ||
                            (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]));
        if (shouldInclude) [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
}

#pragma mark - Mod & Shader Loading

- (void)loadListWithType:(NSInteger)type {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    BOOL isMod = (type == 1);
    NSInteger offset = isMod ? self.currentModOffset : self.currentShaderOffset;
    
    if (offset == 0) [self.loadingIndicator startAnimating];
    
    NSMutableDictionary *filters = [@{@"limit": @30, @"offset": @(offset)} mutableCopy];
    if (self.currentSearchQuery.length > 0) filters[@"query"] = self.currentSearchQuery;
    if (self.currentGameVersion.length > 0) filters[@"version"] = self.currentGameVersion;
    
    void (^completion)(NSArray *, NSError *) = ^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            UITableView *tableView = isMod ? self.modTableView : self.shaderTableView;
            [tableView.refreshControl endRefreshing];
            self.isLoadingMore = NO;
            
            NSMutableArray *list = isMod ? self.modList : self.shaderList;
            BOOL *hasMore = isMod ? &self->_hasMoreMods : &self->_hasMoreShaders;
            NSInteger *currentOffset = isMod ? &self->_currentModOffset : &self->_currentShaderOffset;
            
            if (results) {
                if (offset == 0) [list removeAllObjects];
                [list addObjectsFromArray:results];
                *hasMore = (results.count >= 30);
                *currentOffset += results.count;
                [tableView reloadData];
                self.emptyLabel.hidden = (list.count > 0);
            } else if (error) {
                [self showError:error.localizedDescription];
            }
        });
    };
    
    if (isMod) {
        [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:completion];
    } else {
        [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:completion];
    }
}

- (void)refreshModList {
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self loadListWithType:1];
}

- (void)loadModList {
    [self loadListWithType:1];
}

- (void)searchMods:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

- (void)refreshShaderList {
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self loadListWithType:2];
}

- (void)loadShaderList {
    [self loadListWithType:2];
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"选择游戏版本" items:@[@"全部版本", @"1.21", @"1.20.4", @"1.20.1", @"1.19.4", @"1.19.2", @"1.18.2", @"1.16.5", @"1.12.2", @"1.8.9"] handler:^(NSString *selected) {
            self.currentGameVersion = [selected isEqualToString:@"全部版本"] ? nil : selected;
            [self reloadCurrentList];
        }];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"排序方式" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"排序方式" items:@[@"关注度", @"下载数", @"最近更新", @"最新发布", @"相关性"] handler:^(NSString *selected) {
            NSDictionary *map = @{@"关注度": @"follows", @"下载数": @"downloads", @"最近更新": @"updated", @"最新发布": @"newest", @"相关性": @"relevance"};
            self.currentSortField = map[selected];
            [self reloadCurrentList];
        }];
    }]];
    
    if (tabIndex == 1) {
        [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self showPickerWithTitle:@"模组加载器" items:@[@"全部", @"Fabric", @"Forge", @"Quilt", @"NeoForge"] handler:^(NSString *selected) {
                NSDictionary *map = @{@"全部": [NSNull null], @"Fabric": @"fabric", @"Forge": @"forge", @"Quilt": @"quilt", @"NeoForge": @"neoforge"};
                id value = map[selected];
                self.currentModLoader = (value == [NSNull null]) ? nil : value;
                [self reloadCurrentList];
            }];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { [self resetFilters]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)showPickerWithTitle:(NSString *)title items:(NSArray *)items handler:(void (^)(NSString *))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *item in items) {
        [alert addAction:[UIAlertAction actionWithTitle:item style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { handler(item); }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)presentAlert:(UIAlertController *)alert fromView:(UIView *)sourceView {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
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

#pragma mark - Search Delegate

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

#pragma mark - CollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *date = [version[@"releaseTime"] length] >= 10 ? [version[@"releaseTime"] substringToIndex:10] : version[@"releaseTime"];
    [cell configureWithVersionId:version[@"id"] date:date type:version[@"type"]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self showLoaderSelectionForVersion:self.filteredVersions[indexPath.row]];
}

#pragma mark - Loader Selection

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    LoaderSelectionViewController *loaderVC = [[LoaderSelectionViewController alloc] init];
    
    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf proceedWithVersion:version loaderType:loaderType installFabricAPI:installFabricAPI];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loaderVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.preferredContentSize = CGSizeMake(400, 500);
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI {
    NSString *versionId = version[@"id"];
    
    if ([loaderType isEqualToString:@"vanilla"]) {
        [self downloadVersion:version withLoader:nil];
    } else if ([loaderType isEqualToString:@"fabric"]) {
        [self openInstaller:@"Fabric" version:versionId installAPI:installFabricAPI];
    } else if ([loaderType isEqualToString:@"forge"]) {
        [self openInstaller:@"Forge" version:versionId installAPI:NO];
    } else {
        [self showError:[NSString stringWithFormat:@"%@ 安装器暂未实现", loaderType]];
    }
}

- (void)openInstaller:(NSString *)type version:(NSString *)versionId installAPI:(BOOL)installAPI {
    UIViewController *installerVC;
    
    if ([type isEqualToString:@"Fabric"]) {
        FabricInstallViewController *fabricVC = [[FabricInstallViewController alloc] init];
        fabricVC.gameVersion = versionId;
        fabricVC.shouldInstallAPI = installAPI;
        installerVC = fabricVC;
    } else {
        ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
        forgeVC.gameVersion = versionId;
        installerVC = forgeVC;
    }
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, NSError *) = ^(BOOL success, NSString *profileName, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (success) {
            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 安装成功\n配置文件: %@", type, profileName]];
        } else {
            [strongSelf showError:error.localizedDescription ?: [NSString stringWithFormat:@"%@ 安装失败", type]];
        }
    };
    
    if ([type isEqualToString:@"Fabric"]) ((FabricInstallViewController *)installerVC).completionHandler = completion;
    else ((ForgeInstallViewController *)installerVC).completionHandler = completion;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:installerVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装成功" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) return self.modList.count + (self.hasMoreMods ? 1 : 0);
    if (tableView == self.shaderTableView) return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    NSString *cellId = isMod ? @"ModCell" : @"ShaderCell";
    
    // Loading cell
    if ((isMod && indexPath.row == list.count && hasMore) || (!isMod && indexPath.row == list.count && hasMore)) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    
    ModernAssetCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId forIndexPath:indexPath];
    [cell configureWithData:list[indexPath.row] type:isMod ? @"mod" : @"shader"];
    [cell.downloadButton addTarget:self action:(isMod ? @selector(downloadMod:) : @selector(downloadShader:)) forControlEvents:UIControlEventTouchUpInside];
    cell.downloadButton.tag = indexPath.row;
    
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    
    if (indexPath.row == list.count - 5 && hasMore && !self.isLoadingMore) {
        [self loadListWithType:isMod ? 1 : 2];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    
    if (indexPath.row == list.count && hasMore) {
        [self loadListWithType:isMod ? 1 : 2];
        return;
    }
    
    if (isMod) [self downloadModAtIndexPath:indexPath];
    else [self downloadShaderAtIndexPath:indexPath];
}

#pragma mark - Download Actions

- (void)downloadMod:(UIButton *)sender {
    [self downloadModAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]];
}

- (void)downloadModAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.modList.count) return;
    
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:self.modList[indexPath.row]];
    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    
    [self presentNavControllerWithRoot:versionVC];
}

- (void)downloadShader:(UIButton *)sender {
    [self downloadShaderAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;
    
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:self.shaderList[indexPath.row]];
    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;
    
    [self presentNavControllerWithRoot:versionVC];
}

- (void)presentNavControllerWithRoot:(UIViewController *)rootViewController {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:rootViewController];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Version View Controller Delegates

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    [self handleVersionSelection:viewController version:version isMod:YES];
}

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    [self handleVersionSelection:viewController version:version isMod:NO];
}

- (void)handleVersionSelection:(UIViewController *)viewController version:(id)version isMod:(BOOL)isMod {
    NSDictionary *primaryFile = [version valueForKey:@"primaryFile"];
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }
    
    NSString *displayName = isMod ? ((ModVersionViewController *)viewController).modItem.displayName : ((ShaderVersionViewController *)viewController).shaderItem.displayName;
    NSString *fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.%@", displayName, isMod ? @"jar" : @"zip"];
    
    id item = isMod ? (id)((ModVersionViewController *)viewController).modItem : (id)((ShaderVersionViewController *)viewController).shaderItem;
    [item setValue:primaryFile[@"url"] forKey:@"selectedVersionDownloadURL"];
    [item setValue:fileName forKey:@"fileName"];
    
    __weak typeof(self) weakSelf = self;
    [viewController dismissViewControllerAnimated:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        isMod ? [strongSelf startDownloadForModItem:item] : [strongSelf startDownloadForShaderItem:item];
    }];
}

- (void)startDownloadForModItem:(ModItem *)item {
    [self startDownloadWithItem:item service:[ModService sharedService] type:@"模组"];
}

- (void)startDownloadForShaderItem:(ShaderItem *)item {
    [self startDownloadWithItem:item service:[ShaderService sharedService] type:@"光影"];
}

- (void)startDownloadWithItem:(id)item service:(id)service type:(NSString *)type {
    UIAlertController *alert = [self createDownloadingAlert:((ModItem *)item).displayName];
    [self presentViewController:alert animated:YES completion:nil];
    
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                } else {
                    UIAlertController *success = [UIAlertController alertControllerWithTitle:@"下载成功" message:[NSString stringWithFormat:@"%@ 已安装", ((ModItem *)item).displayName] preferredStyle:UIAlertControllerStyleAlert];
                    [successUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 100;
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    [tv registerClass:[ModernAssetCell class] forCellReuseIdentifier:identifier];
    tv.hidden = YES;
    
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:(type == 1 ? @selector(refreshModList) : @selector(refreshShaderList)) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = refresh;
    
    [self.view addSubview:tv];
    
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    if (type == 1) self.modTableView = tv;
    else self.shaderTableView = tv;
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

#pragma mark - Tab & Data Loading

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
    
    if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        if (self.modList.count == 0) [self loadModList];
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        if (self.shaderList.count == 0) [self loadShaderList];
    }
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *urlString = [downloadSource isEqualToString:@"bmclapi"] ?
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" :
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyVersionFilter];
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
        BOOL shouldInclude = (filterIndex == 0) ||
                            (filterIndex == 1 && [type isEqualToString:@"release"]) ||
                            (filterIndex == 2 && [type isEqualToString:@"snapshot"]) ||
                            (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]));
        if (shouldInclude) [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
}

#pragma mark - Mod & Shader Loading

- (void)loadListWithType:(NSInteger)type {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    BOOL isMod = (type == 1);
    NSInteger offset = isMod ? self.currentModOffset : self.currentShaderOffset;
    
    if (offset == 0) [self.loadingIndicator startAnimating];
    
    NSMutableDictionary *filters = [@{@"limit": @30, @"offset": @(offset)} mutableCopy];
    if (self.currentSearchQuery.length > 0) filters[@"query"] = self.currentSearchQuery;
    if (self.currentGameVersion.length > 0) filters[@"version"] = self.currentGameVersion;
    
    void (^completion)(NSArray *, NSError *) = ^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            UITableView *tableView = isMod ? self.modTableView : self.shaderTableView;
            [tableView.refreshControl endRefreshing];
            self.isLoadingMore = NO;
            
            NSMutableArray *list = isMod ? self.modList : self.shaderList;
            BOOL *hasMore = isMod ? &self->_hasMoreMods : &self->_hasMoreShaders;
            NSInteger *currentOffset = isMod ? &self->_currentModOffset : &self->_currentShaderOffset;
            
            if (results) {
                if (offset == 0) [list removeAllObjects];
                [list addObjectsFromArray:results];
                *hasMore = (results.count >= 30);
                *currentOffset += results.count;
                [tableView reloadData];
                self.emptyLabel.hidden = (list.count > 0);
            } else if (error) {
                [self showError:error.localizedDescription];
            }
        });
    };
    
    if (isMod) {
        [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:completion];
    } else {
        [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:completion];
    }
}

- (void)refreshModList {
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self loadListWithType:1];
}

- (void)loadModList {
    [self loadListWithType:1];
}

- (void)searchMods:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

- (void)refreshShaderList {
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self loadListWithType:2];
}

- (void)loadShaderList {
    [self loadListWithType:2];
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"选择游戏版本" items:@[@"全部版本", @"1.21", @"1.20.4", @"1.20.1", @"1.19.4", @"1.19.2", @"1.18.2", @"1.16.5", @"1.12.2", @"1.8.9"] handler:^(NSString *selected) {
            self.currentGameVersion = [selected isEqualToString:@"全部版本"] ? nil : selected;
            [self reloadCurrentList];
        }];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"排序方式" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"排序方式" items:@[@"关注度", @"下载数", @"最近更新", @"最新发布", @"相关性"] handler:^(NSString *selected) {
            NSDictionary *map = @{@"关注度": @"follows", @"下载数": @"downloads", @"最近更新": @"updated", @"最新发布": @"newest", @"相关性": @"relevance"};
            self.currentSortField = map[selected];
            [self reloadCurrentList];
        }];
    }]];
    
    if (tabIndex == 1) {
        [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self showPickerWithTitle:@"模组加载器" items:@[@"全部", @"Fabric", @"Forge", @"Quilt", @"NeoForge"] handler:^(NSString *selected) {
                NSDictionary *map = @{@"全部": [NSNull null], @"Fabric": @"fabric", @"Forge": @"forge", @"Quilt": @"quilt", @"NeoForge": @"neoforge"};
                id value = map[selected];
                self.currentModLoader = (value == [NSNull null]) ? nil : value;
                [self reloadCurrentList];
            }];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { [self resetFilters]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)showPickerWithTitle:(NSString *)title items:(NSArray *)items handler:(void (^)(NSString *))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *item in items) {
        [alert addAction:[UIAlertAction actionWithTitle:item style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { handler(item); }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)presentAlert:(UIAlertController *)alert fromView:(UIView *)sourceView {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
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

#pragma mark - Search Delegate

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

#pragma mark - CollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *date = [version[@"releaseTime"] length] >= 10 ? [version[@"releaseTime"] substringToIndex:10] : version[@"releaseTime"];
    [cell configureWithVersionId:version[@"id"] date:date type:version[@"type"]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self showLoaderSelectionForVersion:self.filteredVersions[indexPath.row]];
}

#pragma mark - Loader Selection

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    LoaderSelectionViewController *loaderVC = [[LoaderSelectionViewController alloc] init];
    
    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf proceedWithVersion:version loaderType:loaderType installFabricAPI:installFabricAPI];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loaderVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.preferredContentSize = CGSizeMake(400, 500);
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI {
    NSString *versionId = version[@"id"];
    
    if ([loaderType isEqualToString:@"vanilla"]) {
        [self downloadVersion:version withLoader:nil];
    } else if ([loaderType isEqualToString:@"fabric"]) {
        [self openInstaller:@"Fabric" version:versionId installAPI:installFabricAPI];
    } else if ([loaderType isEqualToString:@"forge"]) {
        [self openInstaller:@"Forge" version:versionId installAPI:NO];
    } else {
        [self showError:[NSString stringWithFormat:@"%@ 安装器暂未实现", loaderType]];
    }
}

- (void)openInstaller:(NSString *)type version:(NSString *)versionId installAPI:(BOOL)installAPI {
    UIViewController *installerVC;
    
    if ([type isEqualToString:@"Fabric"]) {
        FabricInstallViewController *fabricVC = [[FabricInstallViewController alloc] init];
        fabricVC.gameVersion = versionId;
        fabricVC.shouldInstallAPI = installAPI;
        installerVC = fabricVC;
    } else {
        ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
        forgeVC.gameVersion = versionId;
        installerVC = forgeVC;
    }
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, NSError *) = ^(BOOL success, NSString *profileName, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (success) {
            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 安装成功\n配置文件: %@", type, profileName]];
        } else {
            [strongSelf showError:error.localizedDescription ?: [NSString stringWithFormat:@"%@ 安装失败", type]];
        }
    };
    
    if ([type isEqualToString:@"Fabric"]) ((FabricInstallViewController *)installerVC).completionHandler = completion;
    else ((ForgeInstallViewController *)installerVC).completionHandler = completion;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:installerVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装成功" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) return self.modList.count + (self.hasMoreMods ? 1 : 0);
    if (tableView == self.shaderTableView) return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    NSString *cellId = isMod ? @"ModCell" : @"ShaderCell";
    
    // Loading cell
    if ((isMod && indexPath.row == list.count && hasMore) || (!isMod && indexPath.row == list.count && hasMore)) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    
    ModernAssetCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId forIndexPath:indexPath];
    [cell configureWithData:list[indexPath.row] type:isMod ? @"mod" : @"shader"];
    [cell.downloadButton addTarget:self action:(isMod ? @selector(downloadMod:) : @selector(downloadShader:)) forControlEvents:UIControlEventTouchUpInside];
    cell.downloadButton.tag = indexPath.row;
    
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    
    if (indexPath.row == list.count - 5 && hasMore && !self.isLoadingMore) {
        [self loadListWithType:isMod ? 1 : 2];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    
    if (indexPath.row == list.count && hasMore) {
        [self loadListWithType:isMod ? 1 : 2];
        return;
    }
    
    if (isMod) [self downloadModAtIndexPath:indexPath];
    else [self downloadShaderAtIndexPath:indexPath];
}

#pragma mark - Download Actions

- (void)downloadMod:(UIButton *)sender {
    [self downloadModAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]];
}

- (void)downloadModAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.modList.count) return;
    
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:self.modList[indexPath.row]];
    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    
    [self presentNavControllerWithRoot:versionVC];
}

- (void)downloadShader:(UIButton *)sender {
    [self downloadShaderAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;
    
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:self.shaderList[indexPath.row]];
    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;
    
    [self presentNavControllerWithRoot:versionVC];
}

- (void)presentNavControllerWithRoot:(UIViewController *)rootViewController {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:rootViewController];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Version View Controller Delegates

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    [self handleVersionSelection:viewController version:version isMod:YES];
}

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    [self handleVersionSelection:viewController version:version isMod:NO];
}

- (void)handleVersionSelection:(UIViewController *)viewController version:(id)version isMod:(BOOL)isMod {
    NSDictionary *primaryFile = [version valueForKey:@"primaryFile"];
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }
    
    NSString *displayName = isMod ? ((ModVersionViewController *)viewController).modItem.displayName : ((ShaderVersionViewController *)viewController).shaderItem.displayName;
    NSString *fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.%@", displayName, isMod ? @"jar" : @"zip"];
    
    id item = isMod ? (id)((ModVersionViewController *)viewController).modItem : (id)((ShaderVersionViewController *)viewController).shaderItem;
    [item setValue:primaryFile[@"url"] forKey:@"selectedVersionDownloadURL"];
    [item setValue:fileName forKey:@"fileName"];
    
    __weak typeof(self) weakSelf = self;
    [viewController dismissViewControllerAnimated:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        isMod ? [strongSelf startDownloadForModItem:item] : [strongSelf startDownloadForShaderItem:item];
    }];
}

- (void)startDownloadForModItem:(ModItem *)item {
    [self startDownloadWithItem:item service:[ModService sharedService] type:@"模组"];
}

- (void)startDownloadForShaderItem:(ShaderItem *)item {
    [self startDownloadWithItem:item service:[ShaderService sharedService] type:@"光影"];
}

- (void)startDownloadWithItem:(id)item service:(id)service type:(NSString *)type {
    UIAlertController *alert = [self createDownloadingAlert:((ModItem *)item).displayName];
    [self presentViewController:alert animated:YES completion:nil];
    
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                } else {
                    UIAlertController *success = [UIAlertController alertControllerWithTitle:@"下载成功" message:[NSString stringWithFormat:@"%@ 已安装", ((ModItem *)item).displayName] preferredStyle:UIAlertControllerStyleAlert];
                    [success addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:success animated:YES completion:nil];
                }
            }];
        });
    };
    
    if ([type isEqualToString:@"模组"]) {
        [service downloadMod:item toProfile:profileName completion:completion];
    } else {
        [service downloadShader:item toProfile:profileName completion:completion];
    }
}

- (UIAlertController *)createDownloadingAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"正在下载" message:message preferredStyle:UIAlertControllerStyleAlert];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:alert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    
    return alert;
}

#pragma mark - Vanilla Version Download

- (void)downloadVersion:(NSDictionary *)version withLoader:(NSString *)loader {
    if (![self isNetworkAvailable]) {
        [self showError:@"网络不可用，请检查网络连接"];
        return;
    }
    
    NSString *versionId = version[@"id"];
    
    NSMutableDictionary *profile = [@{
        @"name": versionId,
        @"lastVersionId": versionId,
        @"type": @"custom",
        @"created": [NSDate date].description
    } mutableCopy];
    
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    [self setupDownloadTaskForVersion:version];
}

- (void)setupDownloadTaskForVersion:(NSDictionary *)version {
    __weak typeof(self) weakSelf = self;
    
    self.downloadingAlert = [UIAlertController alertControllerWithTitle:@"下载中" message:@"正在准备下载..." preferredStyle:UIAlertControllerStyleAlert];
    
    [self.downloadingAlert addAction:[UIAlertAction actionWithTitle:@"查看详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (strongSelf.downloadTask) {
            strongSelf.progressVC = [[DownloadProgressViewController alloc] initWithTask:strongSelf.downloadTask];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:strongSelf.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [strongSelf presentViewController:nav animated:YES completion:nil];
        }
    }]];
    
    [self.downloadingAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (strongSelf.downloadTask) {
            [strongSelf.downloadTask.progress cancel];
            strongSelf.downloadTask = nil;
        }
        strongSelf.view.userInteractionEnabled = YES;
        [strongSelf.loadingIndicator stopAnimating];
    }]];
    
    [self presentViewController:self.downloadingAlert animated:YES completion:nil];
    [self.loadingIndicator startAnimating];
    
    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;
    
    self.downloadTask.retryCallback = ^(NSInteger retryCount, NSInteger maxRetryCount) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (strongSelf.downloadingAlert) {
                strongSelf.downloadingAlert.message = [NSString stringWithFormat:@"下载失败，正在重试 (%ld/%ld)...", (long)retryCount, (long)maxRetryCount];
            }
        });
    };
    
    self.downloadTask.handleError = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.view.userInteractionEnabled = YES;
            [strongSelf.loadingIndicator stopAnimating];
            strongSelf.downloadTask = nil;
            strongSelf.progressVC = nil;
            strongSelf.downloadingAlert = nil;
            [strongSelf showError:@"版本下载失败，请检查网络连接"];
        });
    };
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        [strongSelf.downloadTask downloadVersion:version];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) innerStrongSelf = weakSelf;
            if (!innerStrongSelf) return;
            
            [innerStrongSelf.downloadTask.progress addObserver:innerStrongSelf
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)@"DownloadProgressContext"];
        });
    });
}

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
        returnUILabel *)createLabelWithFont:(UIFont *)font color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = lines;
    [self.contentContainer addSubview:label];
    return label;
}

- (void)setupTagsStack {
    self.tagsStack = [[UIStackView alloc] init];
    self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
    self.tagsStack.spacing = 6;
    self.tagsStack.distribution = UIStackViewDistributionFill;
    [self.contentContainer addSubview:self.tagsStack];
}

- (void)setupDownloadButton {
    self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
    self.downloadButton.tintColor = [UIColor systemGreenColor];
    self.downloadButton.layer.cornerRadius = 20;
    [self.contentContainer addSubview:self.downloadButton];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        [self.blurView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [self.blurView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
        [self.blurView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
        [self.blurView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],
        
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.blurView.contentView.topAnchor constant:12],
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.blurView.contentView.leadingAnchor constant:12],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.blurView.contentView.trailingAnchor constant:-12],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.blurView.contentView.bottomAnchor constant:-12],
        
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
}

- (void)configureWithData:(NSDictionary *)data type:(NSString *)type {
    self.titleLabel.text = data[@"title"] ?: data[@"slug"] ?: @"Unknown";
    self.descLabel.text = data[@"description"] ?: @"";
    
    NSString *author = data[@"author"] ?: @"Unknown";
    NSString *downloadsStr = [self formatDownloadCount:data[@"downloads"]];
    self.metaLabel.text = [NSString stringWithFormat:@"%@ • %@ 下载", author, downloadsStr];
    
    NSString *iconUrl = data[@"imageUrl"] ?: data[@"icon_url"];
    NSString *fallbackIcon = [type isEqualToString:@"mod"] ? @"puzzlepiece.fill" : @"paintbrush.fill";
    UIColor *fallbackColor = [type isEqualToString:@"mod"] ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
    [self loadIconFromURL:iconUrl fallbackSystemImage:fallbackIcon tintColor:fallbackColor];
    
    [self setupTags:data[@"categories"]];
}

- (NSString *)formatDownloadCount:(NSNumber *)downloads {
    if (!downloads) return @"0";
    NSInteger dl = [downloads integerValue];
    if (dl >= 1000000) return [NSString stringWithFormat:@"%.1fM", dl / 1000000.0];
    if (dl >= 1000) return [NSString stringWithFormat:@"%.1fK", dl / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)dl];
}

- (void)loadIconFromURL:(NSString *)iconUrl fallbackSystemImage:(NSString *)systemImage tintColor:(UIColor *)tintColor {
    if (iconUrl.length > 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
            if (data) {
                UIImage *image = [UIImage imageWithData:data];
                dispatch_async(dispatch_get_main_queue(), ^{ self.iconView.image = image; });
            }
        });
    } else {
        self.iconView.image = [UIImage systemImageNamed:systemImage];
        self.iconView.tintColor = tintColor;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    }
}

- (void)setupTags:(NSArray *)categories {
    [self.tagsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    NSArray *cats = categories ?: @[];
    for (NSInteger i = 0; i < MIN(3, cats.count); i++) {
        if ([cats[i] isKindOfClass:[NSString class]]) {
            [self.tagsStack addArrangedSubview:[self createTagLabel:cats[i]]];
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
@end

@implementation LoaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
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
    
    UIView *separator = [[UIView alloc] init];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [self.contentView addSubview:separator];
    
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
        
        [separator.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [separator.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5]
    ]];
    
    return self;
}

@end

#pragma mark - Loader Selection View Controller

@interface LoaderSelectionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) void (^completion)(NSString *loader, BOOL installAPI);
@property (nonatomic, strong) NSArray *loaders;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *apiContainer;
@property (nonatomic, strong) UISwitch *apiSwitch;
@property (nonatomic, strong) NSString *selectedLoader;
@end

@implementation LoaderSelectionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"选择安装方式";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.loaders = @[
        @{@"id": @"vanilla", @"name": @"原版 (Vanilla)", @"desc": @"纯净 Minecraft，不包含任何模组加载器", @"icon": @"cube.fill", @"color": [UIColor systemGrayColor]},
        @{@"id": @"fabric", @"name": @"Fabric", @"desc": @"轻量级模组加载器，适合小型模组", @"icon": @"bolt.fill", @"color": [UIColor systemOrangeColor]},
        @{@"id": @"forge", @"name": @"Forge", @"desc": @"经典模组加载器，模组生态丰富", @"icon": @"hammer.fill", @"color": [UIColor systemRedColor]},
        @{@"id": @"neoforge", @"name": @"NeoForge", @"desc": @"Forge 的分支，现代架构", @"icon": @"hammer.fill", @"color": [UIColor systemBrownColor]},
        @{@"id": @"quilt", @"name": @"Quilt", @"desc": @"基于 Fabric 的新一代加载器", @"icon": @"bolt.fill", @"color": [UIColor systemPurpleColor]}
    ];
    
    [self setupTableView];
    [self setupAPIContainer];
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
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupAPIContainer {
    self.apiContainer = [[UIView alloc] init];
    self.apiContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.apiContainer.layer.cornerRadius = 12;
    self.apiContainer.hidden = YES;
    [self.view addSubview:self.apiContainer];
    
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"同时安装 Fabric API";
    label.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    label.textColor = [UIColor labelColor];
    [self.apiContainer addSubview:label];
    
    self.apiSwitch = [[UISwitch alloc] init];
    self.apiSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.apiSwitch.on = YES;
    [self.apiContainer addSubview:self.apiSwitch];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.apiContainer.topAnchor constant:-16],
        
        [self.apiContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.apiContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.apiContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.apiContainer.heightAnchor constraintEqualToConstant:56],
        
        [label.leadingAnchor constraintEqualToAnchor:self.apiContainer.leadingAnchor constant:16],
        [label.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor],
        
        [self.apiSwitch.trailingAnchor constraintEqualToAnchor:self.apiContainer.trailingAnchor constant:-16],
        [self.apiSwitch.centerYAnchor constraintEqualToAnchor:self.apiContainer.centerYAnchor]
    ]];
}

- (void)setupNavigation {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - TableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaders.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    LoaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderCell" forIndexPath:indexPath];
    NSDictionary *loader = self.loaders[indexPath.row];
    
    cell.nameLabel.text = loader[@"name"];
    cell.descLabel.text = loader[@"desc"];
    
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
    cell.iconView.image = [UIImage systemImageNamed:loader[@"icon"] withConfiguration:config];
    cell.iconView.tintColor = loader[@"color"];
    cell.iconView.backgroundColor = [loader[@"color"] colorWithAlphaComponent:0.15];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *loader = self.loaders[indexPath.row];
    self.selectedLoader = loader[@"id"];
    
    if ([self.selectedLoader isEqualToString:@"fabric"]) {
        self.apiContainer.hidden = NO;
        self.apiContainer.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{ self.apiContainer.alpha = 1; }];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认安装" message:@"是否同时安装 Fabric API？大多数模组需要它才能运行。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"安装" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { [self confirmSelection]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"仅 Fabric" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            self.apiSwitch.on = NO;
            [self confirmSelection];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        [self confirmSelection];
    }
}

- (void)confirmSelection {
    if (self.completion) {
        self.completion(self.selectedLoader, self.apiSwitch.isOn);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
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

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
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

#pragma mark - UI Setup

- (void)setupUI {
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupSearchBar];
    [self setupVersionCollectionView];
    [self setupTableView:self.modTableView identifier:@"ModCell" type:1];
    [self setupTableView:self.shaderTableView identifier:@"ShaderCell" type:2];
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

- (void)setupTableView:(UITableView *)tableView identifier:(NSString *)identifier type:(NSInteger)type {
    UITableView *tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    tv.translatesAutoresizingMaskIntoConstraints = NO;
    tv.backgroundColor = [UIColor clearColor];
    tv.dataSource = self;
    tv.delegate = self;
    tv.rowHeight = 100;
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    [tv registerClass:[ModernAssetCell class] forCellReuseIdentifier:identifier];
    tv.hidden = YES;
    
    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:(type == 1 ? @selector(refreshModList) : @selector(refreshShaderList)) forControlEvents:UIControlEventValueChanged];
    tv.refreshControl = refresh;
    
    [self.view addSubview:tv];
    
    [NSLayoutConstraint activateConstraints:@[
        [tv.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:8],
        [tv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [tv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [tv.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
    
    if (type == 1) self.modTableView = tv;
    else self.shaderTableView = tv;
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

#pragma mark - Tab & Data Loading

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
    
    if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        if (self.modList.count == 0) [self loadModList];
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        if (self.shaderList.count == 0) [self loadShaderList];
    }
}

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSString *downloadSource = getPrefObject(@"general.download_source");
    NSString *urlString = [downloadSource isEqualToString:@"bmclapi"] ?
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" :
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json";
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:urlString] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && !jsonError) {
                    self.versionList = json[@"versions"];
                    [self applyVersionFilter];
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
        BOOL shouldInclude = (filterIndex == 0) ||
                            (filterIndex == 1 && [type isEqualToString:@"release"]) ||
                            (filterIndex == 2 && [type isEqualToString:@"snapshot"]) ||
                            (filterIndex == 3 && ([type isEqualToString:@"old_alpha"] || [type isEqualToString:@"old_beta"]));
        if (shouldInclude) [filtered addObject:version];
    }
    
    self.filteredVersions = filtered;
    [self.versionCollectionView reloadData];
}

#pragma mark - Mod & Shader Loading

- (void)loadListWithType:(NSInteger)type {
    if (self.isLoadingMore) return;
    self.isLoadingMore = YES;
    
    BOOL isMod = (type == 1);
    NSInteger offset = isMod ? self.currentModOffset : self.currentShaderOffset;
    
    if (offset == 0) [self.loadingIndicator startAnimating];
    
    NSMutableDictionary *filters = [@{@"limit": @30, @"offset": @(offset)} mutableCopy];
    if (self.currentSearchQuery.length > 0) filters[@"query"] = self.currentSearchQuery;
    if (self.currentGameVersion.length > 0) filters[@"version"] = self.currentGameVersion;
    
    void (^completion)(NSArray *, NSError *) = ^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            UITableView *tableView = isMod ? self.modTableView : self.shaderTableView;
            [tableView.refreshControl endRefreshing];
            self.isLoadingMore = NO;
            
            NSMutableArray *list = isMod ? self.modList : self.shaderList;
            BOOL *hasMore = isMod ? &self->_hasMoreMods : &self->_hasMoreShaders;
            NSInteger *currentOffset = isMod ? &self->_currentModOffset : &self->_currentShaderOffset;
            
            if (results) {
                if (offset == 0) [list removeAllObjects];
                [list addObjectsFromArray:results];
                *hasMore = (results.count >= 30);
                *currentOffset += results.count;
                [tableView reloadData];
                self.emptyLabel.hidden = (list.count > 0);
            } else if (error) {
                [self showError:error.localizedDescription];
            }
        });
    };
    
    if (isMod) {
        [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:completion];
    } else {
        [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:completion];
    }
}

- (void)refreshModList {
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self loadListWithType:1];
}

- (void)loadModList {
    [self loadListWithType:1];
}

- (void)searchMods:(NSString *)query {
    self.currentSearchQuery = query;
    self.currentModOffset = 0;
    self.hasMoreMods = YES;
    [self.modList removeAllObjects];
    [self.modTableView reloadData];
    [self loadModList];
}

- (void)refreshShaderList {
    self.currentShaderOffset = 0;
    self.hasMoreShaders = YES;
    [self.shaderList removeAllObjects];
    [self loadListWithType:2];
}

- (void)loadShaderList {
    [self loadListWithType:2];
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"选择游戏版本" items:@[@"全部版本", @"1.21", @"1.20.4", @"1.20.1", @"1.19.4", @"1.19.2", @"1.18.2", @"1.16.5", @"1.12.2", @"1.8.9"] handler:^(NSString *selected) {
            self.currentGameVersion = [selected isEqualToString:@"全部版本"] ? nil : selected;
            [self reloadCurrentList];
        }];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"排序方式" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [self showPickerWithTitle:@"排序方式" items:@[@"关注度", @"下载数", @"最近更新", @"最新发布", @"相关性"] handler:^(NSString *selected) {
            NSDictionary *map = @{@"关注度": @"follows", @"下载数": @"downloads", @"最近更新": @"updated", @"最新发布": @"newest", @"相关性": @"relevance"};
            self.currentSortField = map[selected];
            [self reloadCurrentList];
        }];
    }]];
    
    if (tabIndex == 1) {
        [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self showPickerWithTitle:@"模组加载器" items:@[@"全部", @"Fabric", @"Forge", @"Quilt", @"NeoForge"] handler:^(NSString *selected) {
                NSDictionary *map = @{@"全部": [NSNull null], @"Fabric": @"fabric", @"Forge": @"forge", @"Quilt": @"quilt", @"NeoForge": @"neoforge"};
                id value = map[selected];
                self.currentModLoader = (value == [NSNull null]) ? nil : value;
                [self reloadCurrentList];
            }];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) { [self resetFilters]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)showPickerWithTitle:(NSString *)title items:(NSArray *)items handler:(void (^)(NSString *))handler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *item in items) {
        [alert addAction:[UIAlertAction actionWithTitle:item style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) { handler(item); }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentAlert:alert fromView:self.filterButton];
}

- (void)presentAlert:(UIAlertController *)alert fromView:(UIView *)sourceView {
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = sourceView;
        alert.popoverPresentationController.sourceRect = sourceView.bounds;
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

#pragma mark - Search Delegate

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

#pragma mark - CollectionView DataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    VersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCard" forIndexPath:indexPath];
    NSDictionary *version = self.filteredVersions[indexPath.row];
    NSString *date = [version[@"releaseTime"] length] >= 10 ? [version[@"releaseTime"] substringToIndex:10] : version[@"releaseTime"];
    [cell configureWithVersionId:version[@"id"] date:date type:version[@"type"]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self showLoaderSelectionForVersion:self.filteredVersions[indexPath.row]];
}

#pragma mark - Loader Selection

- (void)showLoaderSelectionForVersion:(NSDictionary *)version {
    LoaderSelectionViewController *loaderVC = [[LoaderSelectionViewController alloc] init];
    
    __weak typeof(self) weakSelf = self;
    loaderVC.completion = ^(NSString *loaderType, BOOL installFabricAPI) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf proceedWithVersion:version loaderType:loaderType installFabricAPI:installFabricAPI];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:loaderVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        nav.preferredContentSize = CGSizeMake(400, 500);
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)proceedWithVersion:(NSDictionary *)version loaderType:(NSString *)loaderType installFabricAPI:(BOOL)installFabricAPI {
    NSString *versionId = version[@"id"];
    
    if ([loaderType isEqualToString:@"vanilla"]) {
        [self downloadVersion:version withLoader:nil];
    } else if ([loaderType isEqualToString:@"fabric"]) {
        [self openInstaller:@"Fabric" version:versionId installAPI:installFabricAPI];
    } else if ([loaderType isEqualToString:@"forge"]) {
        [self openInstaller:@"Forge" version:versionId installAPI:NO];
    } else {
        [self showError:[NSString stringWithFormat:@"%@ 安装器暂未实现", loaderType]];
    }
}

- (void)openInstaller:(NSString *)type version:(NSString *)versionId installAPI:(BOOL)installAPI {
    UIViewController *installerVC;
    
    if ([type isEqualToString:@"Fabric"]) {
        FabricInstallViewController *fabricVC = [[FabricInstallViewController alloc] init];
        fabricVC.gameVersion = versionId;
        fabricVC.shouldInstallAPI = installAPI;
        installerVC = fabricVC;
    } else {
        ForgeInstallViewController *forgeVC = [[ForgeInstallViewController alloc] init];
        forgeVC.gameVersion = versionId;
        installerVC = forgeVC;
    }
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL, NSString *, NSError *) = ^(BOOL success, NSString *profileName, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (success) {
            [strongSelf showSuccessMessage:[NSString stringWithFormat:@"%@ 安装成功\n配置文件: %@", type, profileName]];
        } else {
            [strongSelf showError:error.localizedDescription ?: [NSString stringWithFormat:@"%@ 安装失败", type]];
        }
    };
    
    if ([type isEqualToString:@"Fabric"]) ((FabricInstallViewController *)installerVC).completionHandler = completion;
    else ((ForgeInstallViewController *)installerVC).completionHandler = completion;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:installerVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showSuccessMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"安装成功" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) return self.modList.count + (self.hasMoreMods ? 1 : 0);
    if (tableView == self.shaderTableView) return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    NSString *cellId = isMod ? @"ModCell" : @"ShaderCell";
    
    // Loading cell
    if ((isMod && indexPath.row == list.count && hasMore) || (!isMod && indexPath.row == list.count && hasMore)) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    
    ModernAssetCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId forIndexPath:indexPath];
    [cell configureWithData:list[indexPath.row] type:isMod ? @"mod" : @"shader"];
    [cell.downloadButton addTarget:self action:(isMod ? @selector(downloadMod:) : @selector(downloadShader:)) forControlEvents:UIControlEventTouchUpInside];
    cell.downloadButton.tag = indexPath.row;
    
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    
    if (indexPath.row == list.count - 5 && hasMore && !self.isLoadingMore) {
        [self loadListWithType:isMod ? 1 : 2];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    BOOL isMod = (tableView == self.modTableView);
    NSArray *list = isMod ? self.modList : self.shaderList;
    BOOL hasMore = isMod ? self.hasMoreMods : self.hasMoreShaders;
    
    if (indexPath.row == list.count && hasMore) {
        [self loadListWithType:isMod ? 1 : 2];
        return;
    }
    
    if (isMod) [self downloadModAtIndexPath:indexPath];
    else [self downloadShaderAtIndexPath:indexPath];
}

#pragma mark - Download Actions

- (void)downloadMod:(UIButton *)sender {
    [self downloadModAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]];
}

- (void)downloadModAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.modList.count) return;
    
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:self.modList[indexPath.row]];
    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    
    [self presentNavControllerWithRoot:versionVC];
}

- (void)downloadShader:(UIButton *)sender {
    [self downloadShaderAtIndexPath:[NSIndexPath indexPathForRow:sender.tag inSection:0]];
}

- (void)downloadShaderAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.shaderList.count) return;
    
    ShaderItem *shaderItem = [[ShaderItem alloc] initWithOnlineData:self.shaderList[indexPath.row]];
    ShaderVersionViewController *versionVC = [[ShaderVersionViewController alloc] init];
    versionVC.shaderItem = shaderItem;
    versionVC.delegate = self;
    
    [self presentNavControllerWithRoot:versionVC];
}

- (void)presentNavControllerWithRoot:(UIViewController *)rootViewController {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:rootViewController];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Version View Controller Delegates

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    [self handleVersionSelection:viewController version:version isMod:YES];
}

- (void)shaderVersionViewController:(ShaderVersionViewController *)viewController didSelectVersion:(ShaderVersion *)version {
    [self handleVersionSelection:viewController version:version isMod:NO];
}

- (void)handleVersionSelection:(UIViewController *)viewController version:(id)version isMod:(BOOL)isMod {
    NSDictionary *primaryFile = [version valueForKey:@"primaryFile"];
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showError:@"未找到有效的下载链接"];
        return;
    }
    
    NSString *displayName = isMod ? ((ModVersionViewController *)viewController).modItem.displayName : ((ShaderVersionViewController *)viewController).shaderItem.displayName;
    NSString *fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.%@", displayName, isMod ? @"jar" : @"zip"];
    
    id item = isMod ? (id)((ModVersionViewController *)viewController).modItem : (id)((ShaderVersionViewController *)viewController).shaderItem;
    [item setValue:primaryFile[@"url"] forKey:@"selectedVersionDownloadURL"];
    [item setValue:fileName forKey:@"fileName"];
    
    __weak typeof(self) weakSelf = self;
    [viewController dismissViewControllerAnimated:YES completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        isMod ? [strongSelf startDownloadForModItem:item] : [strongSelf startDownloadForShaderItem:item];
    }];
}

- (void)startDownloadForModItem:(ModItem *)item {
    [self startDownloadWithItem:item service:[ModService sharedService] type:@"模组"];
}

- (void)startDownloadForShaderItem:(ShaderItem *)item {
    [self startDownloadWithItem:item service:[ShaderService sharedService] type:@"光影"];
}

- (void)startDownloadWithItem:(id)item service:(id)service type:(NSString *)type {
    UIAlertController *alert = [self createDownloadingAlert:((ModItem *)item).displayName];
    [self presentViewController:alert animated:YES completion:nil];
    
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    
    __weak typeof(self) weakSelf = self;
    void (^completion)(NSError *) = ^(NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [strongSelf showError:error.localizedDescription];
                } else {
                    UIAlertController *success = [UIAlertController alertControllerWithTitle:@"下载成功" message:[NSString stringWithFormat:@"%@ 已安装", ((ModItem *)item).displayName] preferredStyle:UIAlertControllerStyleAlert];
                    [success addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:success animated:YES completion:nil];
                }
            }];
        });
    };
    
    if ([type isEqualToString:@"模组"]) {
        [service downloadMod:item toProfile:profileName completion:completion];
    } else {
        [service downloadShader:item toProfile:profileName completion:completion];
    }
}

- (UIAlertController *)createDownloadingAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"正在下载" message:message preferredStyle:UIAlertControllerStyleAlert];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:alert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    
    return alert;
}

#pragma mark - Vanilla Version Download

- (void)downloadVersion:(NSDictionary *)version withLoader:(NSString *)loader {
    if (![self isNetworkAvailable]) {
        [self showError:@"网络不可用，请检查网络连接"];
        return;
    }
    
    NSString *versionId = version[@"id"];
    
    NSMutableDictionary *profile = [@{
        @"name": versionId,
        @"lastVersionId": versionId,
        @"type": @"custom",
        @"created": [NSDate date].description
    } mutableCopy];
    
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    [self setupDownloadTaskForVersion:version];
}

- (void)setupDownloadTaskForVersion:(NSDictionary *)version {
    __weak typeof(self) weakSelf = self;
    
    self.downloadingAlert = [UIAlertController alertControllerWithTitle:@"下载中" message:@"正在准备下载..." preferredStyle:UIAlertControllerStyleAlert];
    
    [self.downloadingAlert addAction:[UIAlertAction actionWithTitle:@"查看详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (strongSelf.downloadTask) {
            strongSelf.progressVC = [[DownloadProgressViewController alloc] initWithTask:strongSelf.downloadTask];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:strongSelf.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [strongSelf presentViewController:nav animated:YES completion:nil];
        }
    }]];
    
    [self.downloadingAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (strongSelf.downloadTask) {
            [strongSelf.downloadTask.progress cancel];
            strongSelf.downloadTask = nil;
        }
        strongSelf.view.userInteractionEnabled = YES;
        [strongSelf.loadingIndicator stopAnimating];
    }]];
    
    [self presentViewController:self.downloadingAlert animated:YES completion:nil];
    [self.loadingIndicator startAnimating];
    
    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3;
    
    self.downloadTask.retryCallback = ^(NSInteger retryCount, NSInteger maxRetryCount) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (strongSelf.downloadingAlert) {
                strongSelf.downloadingAlert.message = [NSString stringWithFormat:@"下载失败，正在重试 (%ld/%ld)...", (long)retryCount, (long)maxRetryCount];
            }
        });
    };
    
    self.downloadTask.handleError = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.view.userInteractionEnabled = YES;
            [strongSelf.loadingIndicator stopAnimating];
            strongSelf.downloadTask = nil;
            strongSelf.progressVC = nil;
            strongSelf.downloadingAlert = nil;
            [strongSelf showError:@"版本下载失败，请检查网络连接"];
        });
    };
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        [strongSelf.downloadTask downloadVersion:version];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) innerStrongSelf = weakSelf;
            if (!innerStrongSelf) return;
            
            [innerStrongSelf.downloadTask.progress addObserver:innerStrongSelf
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)@"DownloadProgressContext"];
        });
    });
}

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
                textProgress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
            }
        }
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        if (!strongSelf.progressVC && strongSelf.downloadingAlert) {
            strongSelf.downloadingAlert.message = [strongSelf formatProgressMessage:progress textProgress:textProgress];
        }
        
        if (progress.finished) {
            [strongSelf.downloadTask.progress removeObserver:strongSelf forKeyPath:@"fractionCompleted"];
            lastMsTime = 0; lastSecTime = 0; lastCompletedUnitCount = 0;
            
            strongSelf.view.userInteractionEnabled = YES;
            [strongSelf.loadingIndicator stopAnimating];
            
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
            strongSelf.downloadingAlert = nil;
            
            if (strongSelf.progressVC) {
                [strongSelf.progressVC dismissViewControllerAnimated:YES completion:nil];
                strongSelf.progressVC = nil;
            }
            
            UIAlertController *success = [UIAlertController alertControllerWithTitle:@"下载完成" message:[NSString stringWithFormat:@"%@ 下载完成", strongSelf.downloadTask.metadata[@"id"] ?: @"版本"] preferredStyle:UIAlertControllerStyleAlert];
            [success addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:success animated:YES completion:nil];
            
            strongSelf.downloadTask = nil;
        }
    });
}

- (NSString *)formatProgressMessage:(NSProgress *)progress textProgress:(NSProgress *)textProgress {
    NSString *progressText = textProgress.localizedAdditionalDescription;
    if (!progressText || progressText.length == 0) {
        progressText = [NSString stringWithFormat:@"%.1f%%", progress.fractionCompleted * 100];
    }
    
    NSString *speedText = @"";
    if (textProgress.throughput) {
        NSInteger speed = [textProgress.throughput integerValue];
        if (speed > 1024 * 1024) speedText = [NSString stringWithFormat:@" • %.1f MB/s", speed / (1024.0 * 1024.0)];
        else if (speed > 1024) speedText = [NSString stringWithFormat:@" • %.1f KB/s", speed / 1024.0];
        else if (speed > 0) speedText = [NSString stringWithFormat:@" • %ld B/s", (long)speed];
    }
    
    NSString *etaText = @"";
    if (textProgress.estimatedTimeRemaining) {
        NSInteger eta = [textProgress.estimatedTimeRemaining integerValue];
        if (eta > 3600) etaText = [NSString stringWithFormat:@" • 剩余 %ld小时%ld分", (long)(eta / 3600), (long)((eta % 3600) / 60)];
        else if (eta > 60) etaText = [NSString stringWithFormat:@" • 剩余 %ld分%ld秒", (long)(eta / 60), (long)(eta % 60)];
        else if (eta > 0) etaText = [NSString stringWithFormat:@" • 剩余 %ld秒", (long)eta];
    }
    
    return [NSString stringWithFormat:@"正在下载...\n%@%@%@", progressText, speedText, etaText];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
