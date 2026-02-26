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
#import <QuartzCore/QuartzCore.h>

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

#pragma mark - Modern Asset Cell

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
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        
        // 模糊背景
        UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        self.blurView.translatesAutoresizingMaskIntoConstraints = NO;
        self.blurView.layer.cornerRadius = 16;
        self.blurView.layer.masksToBounds = YES;
        self.blurView.layer.borderWidth = 0.5;
        self.blurView.layer.borderColor = [UIColor separatorColor].CGColor;
        [self.contentView addSubview:self.blurView];
        
        // 内容容器
        self.contentContainer = [[UIView alloc] init];
        self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
        [self.blurView.contentView addSubview:self.contentContainer];
        
        // 图标
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 12;
        self.iconView.clipsToBounds = YES;
        self.iconView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.iconView.contentMode = UIViewContentModeScaleAspectFill;
        [self.contentContainer addSubview:self.iconView];
        
        // 标题
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.numberOfLines = 1;
        [self.contentContainer addSubview:self.titleLabel];
        
        // 描述
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 2;
        [self.contentContainer addSubview:self.descLabel];
        
        // 元信息（下载量、作者）
        self.metaLabel = [[UILabel alloc] init];
        self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.metaLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
        self.metaLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentContainer addSubview:self.metaLabel];
        
        // 标签栈
        self.tagsStack = [[UIStackView alloc] init];
        self.tagsStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsStack.axis = UILayoutConstraintAxisHorizontal;
        self.tagsStack.spacing = 6;
        self.tagsStack.distribution = UIStackViewDistributionFill;
        [self.contentContainer addSubview:self.tagsStack];
        
        // 下载按钮
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        self.downloadButton.layer.cornerRadius = 20;
        [self.contentContainer addSubview:self.downloadButton];
        
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
    
    // 加载图标
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
    
    // 清空并添加标签
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
    
    // 加载图标
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
    
    // 清空并添加标签
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

// 搜索和过滤状态
@property (nonatomic, assign) NSInteger currentModOffset;
@property (nonatomic, assign) NSInteger currentShaderOffset;
@property (nonatomic, assign) BOOL isLoadingMore;
@property (nonatomic, assign) BOOL hasMoreMods;
@property (nonatomic, assign) BOOL hasMoreShaders;
@property (nonatomic, strong) NSString *currentSearchQuery;
@property (nonatomic, strong) NSString *currentGameVersion;
@property (nonatomic, strong) NSString *currentModLoader;
@property (nonatomic, strong) NSString *currentSortField;

// 下载任务相关
@property (nonatomic, strong) MinecraftResourceDownloadTask *downloadTask;
@property (nonatomic, strong) DownloadProgressViewController *progressVC;
@property (nonatomic, strong) UIAlertController *downloadingAlert;

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
    // 初始化
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
    
    // 过滤按钮
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
    
    // 下拉刷新
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
    
    // 下拉刷新
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
    
    if (index == 1) {
        self.searchBar.placeholder = @"搜索模组...";
        if (self.modList.count == 0) {
            [self loadModList];
        }
    } else if (index == 2) {
        self.searchBar.placeholder = @"搜索光影...";
        if (self.shaderList.count == 0) {
            [self loadShaderList];
        }
    }
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
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
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
    
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            [self.modTableView.refreshControl endRefreshing];
            self.isLoadingMore = NO;
            
            if (results) {
                if (self.currentModOffset == 0) {
                    [self.modList removeAllObjects];
                }
                [self.modList addObjectsFromArray:results];
                self.hasMoreMods = (results.count >= 30);
                self.currentModOffset += results.count;
                
                [self.modTableView reloadData];
                self.emptyLabel.hidden = (self.modList.count > 0);
            } else if (error) {
                [self showError:error.localizedDescription];
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
    
    if (self.currentSearchQuery.length > 0) {
        filters[@"query"] = self.currentSearchQuery;
    }
    if (self.currentGameVersion.length > 0) {
        filters[@"version"] = self.currentGameVersion;
    }
    
    [[ModrinthAPI sharedInstance] searchShaderWithFilters:filters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            [self.shaderTableView.refreshControl endRefreshing];
            self.isLoadingMore = NO;
            
            if (results) {
                if (self.currentShaderOffset == 0) {
                    [self.shaderList removeAllObjects];
                }
                [self.shaderList addObjectsFromArray:results];
                self.hasMoreShaders = (results.count >= 30);
                self.currentShaderOffset += results.count;
                
                [self.shaderTableView reloadData];
                self.emptyLabel.hidden = (self.shaderList.count > 0);
            } else if (error) {
                [self showError:error.localizedDescription];
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
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"筛选选项"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 游戏版本
    [alert addAction:[UIAlertAction actionWithTitle:@"选择游戏版本"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self showGameVersionPicker];
    }]];
    
    // 排序方式
    [alert addAction:[UIAlertAction actionWithTitle:@"排序方式"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self showSortOptions];
    }]];
    
    // 模组加载器（仅模组）
    if (tabIndex == 1) {
        [alert addAction:[UIAlertAction actionWithTitle:@"模组加载器"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self showModLoaderPicker];
        }]];
    }
    
    // 重置筛选
    [alert addAction:[UIAlertAction actionWithTitle:@"重置筛选"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self resetFilters];
    }]];
    
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
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = nil;
    self.currentSearchQuery = nil;
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
    [self showVersionDownloadDialog:version];
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) {
        return self.modList.count + (self.hasMoreMods ? 1 : 0);
    } else if (tableView == self.shaderTableView) {
        return self.shaderList.count + (self.hasMoreShaders ? 1 : 0);
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 加载更多
    if (tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    
    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"LoadingCell"];
        cell.textLabel.text = @"加载更多...";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        return cell;
    }
    
    ModernAssetCell *cell;
    if (tableView == self.modTableView) {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
        NSDictionary *mod = self.modList[indexPath.row];
        [cell configureWithMod:mod];
        [cell.downloadButton addTarget:self action:@selector(downloadMod:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    } else {
        cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
        NSDictionary *shader = self.shaderList[indexPath.row];
        [cell configureWithShader:shader];
        [cell.downloadButton addTarget:self action:@selector(downloadShader:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 滚动到底部时加载更多
    if (tableView == self.modTableView && indexPath.row == self.modList.count - 5 && self.hasMoreMods && !self.isLoadingMore) {
        [self loadModList];
    }
    
    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count - 5 && self.hasMoreShaders && !self.isLoadingMore) {
        [self loadShaderList];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // 点击加载更多
    if (tableView == self.modTableView && indexPath.row == self.modList.count && self.hasMoreMods) {
        [self loadModList];
        return;
    }
    
    if (tableView == self.shaderTableView && indexPath.row == self.shaderList.count && self.hasMoreShaders) {
        [self loadShaderList];
        return;
    }
    
    // 点击项目直接下载
    if (tableView == self.modTableView) {
        [self downloadModAtIndexPath:indexPath];
    } else {
        [self downloadShaderAtIndexPath:indexPath];
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
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:versionVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
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
    
    [[ModService sharedService] downloadMod:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [self showError:error.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已安装", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:successAlert animated:YES completion:nil];
                }
            }];
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
    
    [[ShaderService sharedService] downloadShader:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [self showError:error.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已安装", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:successAlert animated:YES completion:nil];
                }
            }];
        });
    }];
}

#pragma mark - Version Download

- (void)showVersionDownloadDialog:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    NSString *versionType = version[@"type"];
    
    NSString *typeDisplay = @"";
    if ([versionType isEqualToString:@"release"]) {
        typeDisplay = @"正式版";
    } else if ([versionType isEqualToString:@"snapshot"]) {
        typeDisplay = @"测试版";
    } else if ([versionType isEqualToString:@"old_alpha"]) {
        typeDisplay = @"远古Alpha版";
    } else if ([versionType isEqualToString:@"old_beta"]) {
        typeDisplay = @"远古Beta版";
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:versionId
                                                                   message:[NSString stringWithFormat:@"类型: %@", typeDisplay]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"下载此版本"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self downloadVersion:version];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)isNetworkAvailable {
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr *)&zeroAddress);
    
    if (reachability == NULL) {
        return NO;
    }
    
    SCNetworkReachabilityFlags flags;
    BOOL success = SCNetworkReachabilityGetFlags(reachability, &flags);
    CFRelease(reachability);
    
    if (!success) {
        return NO;
    }
    
    BOOL isReachable = ((flags & kSCNetworkReachabilityFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkReachabilityFlagsConnectionRequired) != 0);
    
    return (isReachable && !needsConnection);
}

- (void)downloadVersion:(NSDictionary *)version {
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
    
    self.downloadingAlert = [UIAlertController alertControllerWithTitle:@"下载中"
                                                                message:@"正在准备下载..."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    
    __weak DownloadViewController *weakSelf = self;
    
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
            [weakSelf.downloadTask.progress cancel];
            weakSelf.downloadTask = nil;
        }
        weakSelf.view.userInteractionEnabled = YES;
        [weakSelf.loadingIndicator stopAnimating];
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
            [self.downloadTask.progress addObserver:self
                                         forKeyPath:@"fractionCompleted"
                                            options:NSKeyValueObservingOptionInitial
                                            context:(void *)@"DownloadProgressContext"];
        });
    });
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
            // 已显示进度详情
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
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            
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

@end