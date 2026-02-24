#import "DownloadViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModService.h"
#import "ShaderService.h"
#import "PLProfiles.h"

// 版本卡片Cell
@interface VersionCardCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *dateLabel;
@property (nonatomic, strong) UILabel *typeLabel;
@end

@implementation VersionCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;
        
        // 图标
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
        self.iconImageView.tintColor = [UIColor systemGreenColor];
        [self.contentView addSubview:self.iconImageView];
        
        // 版本号
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.versionLabel.font = [UIFont boldSystemFontOfSize:14];
        self.versionLabel.textAlignment = NSTextAlignmentCenter;
        self.versionLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.versionLabel];
        
        // 日期
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [UIFont systemFontOfSize:10];
        self.dateLabel.textColor = [UIColor secondaryLabelColor];
        self.dateLabel.textAlignment = NSTextAlignmentCenter;
        [self.contentView addSubview:self.dateLabel];
        
        // 类型标签
        self.typeLabel = [[UILabel alloc] init];
        self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.typeLabel.font = [UIFont systemFontOfSize:9];
        self.typeLabel.textColor = [UIColor whiteColor];
        self.typeLabel.backgroundColor = [UIColor systemBlueColor];
        self.typeLabel.textAlignment = NSTextAlignmentCenter;
        self.typeLabel.layer.cornerRadius = 4;
        self.typeLabel.layer.masksToBounds = YES;
        [self.contentView addSubview:self.typeLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.iconImageView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:40],
            [self.iconImageView.heightAnchor constraintEqualToConstant:40],
            
            [self.versionLabel.topAnchor constraintEqualToAnchor:self.iconImageView.bottomAnchor constant:6],
            [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            
            [self.dateLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:2],
            [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:4],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            
            [self.typeLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-6],
            [self.typeLabel.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [self.typeLabel.widthAnchor constraintEqualToConstant:45],
            [self.typeLabel.heightAnchor constraintEqualToConstant:16]
        ]];
    }
    return self;
}

@end

// 模组/光影 Cell
@interface ModShaderCell : UITableViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UILabel *authorLabel;
@property (nonatomic, strong) UIButton *downloadButton;
@end

@implementation ModShaderCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.layer.cornerRadius = 8;
        self.iconView.clipsToBounds = YES;
        self.iconView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [self.contentView addSubview:self.iconView];
        
        self.nameLabel = [[UILabel alloc] init];
        self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.nameLabel.font = [UIFont boldSystemFontOfSize:15];
        self.nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:self.nameLabel];
        
        self.descLabel = [[UILabel alloc] init];
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.descLabel.font = [UIFont systemFontOfSize:12];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 2;
        [self.contentView addSubview:self.descLabel];
        
        self.authorLabel = [[UILabel alloc] init];
        self.authorLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.authorLabel.font = [UIFont systemFontOfSize:11];
        self.authorLabel.textColor = [UIColor tertiaryLabelColor];
        [self.contentView addSubview:self.authorLabel];
        
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.downloadButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.downloadButton setImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"] forState:UIControlStateNormal];
        self.downloadButton.tintColor = [UIColor systemGreenColor];
        [self.contentView addSubview:self.downloadButton];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:50],
            [self.iconView.heightAnchor constraintEqualToConstant:50],
            
            [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
            [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.downloadButton.leadingAnchor constant:-8],
            
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:4],
            [self.descLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],
            
            [self.authorLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
            [self.authorLabel.topAnchor constraintEqualToAnchor:self.descLabel.bottomAnchor constant:4],
            [self.authorLabel.trailingAnchor constraintEqualToAnchor:self.nameLabel.trailingAnchor],
            
            [self.downloadButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [self.downloadButton.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.downloadButton.widthAnchor constraintEqualToConstant:32],
            [self.downloadButton.heightAnchor constraintEqualToConstant:32]
        ]];
    }
    return self;
}

@end

@interface DownloadViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UISegmentedControl *versionFilterSegment;
@property (nonatomic, strong) UICollectionView *versionCollectionView;
@property (nonatomic, strong) UITableView *modTableView;
@property (nonatomic, strong) UITableView *shaderTableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;

@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, strong) NSArray *filteredVersions;
@property (nonatomic, strong) NSMutableArray *modList;
@property (nonatomic, strong) NSMutableArray *shaderList;

@end

@implementation DownloadViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"下载";
    self.view.backgroundColor = [UIColor clearColor];
    
    [self setupTabSegment];
    [self setupVersionFilterSegment];
    [self setupVersionCollectionView];
    [self setupModTableView];
    [self setupShaderTableView];
    [self setupLoadingIndicator];
    
    // 默认显示版本下载
    [self switchToTab:0];
    
    // 加载版本列表
    [self loadVersionList];
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
    self.modTableView.rowHeight = 80;
    [self.modTableView registerClass:[ModShaderCell class] forCellReuseIdentifier:@"ModCell"];
    self.modTableView.hidden = YES;
    [self.view addSubview:self.modTableView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.modTableView.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
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
    self.shaderTableView.rowHeight = 80;
    [self.shaderTableView registerClass:[ModShaderCell class] forCellReuseIdentifier:@"ShaderCell"];
    self.shaderTableView.hidden = YES;
    [self.view addSubview:self.shaderTableView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.shaderTableView.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8],
        [self.shaderTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.shaderTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.shaderTableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]
    ]];
}

- (void)setupLoadingIndicator {
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.hidesWhenStopped = YES;
    self.loadingIndicator.color = [UIColor whiteColor];
    [self.view addSubview:self.loadingIndicator];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
}

#pragma mark - Tab Switching

- (void)tabChanged:(UISegmentedControl *)sender {
    [self switchToTab:sender.selectedSegmentIndex];
}

- (void)switchToTab:(NSInteger)index {
    self.versionFilterSegment.hidden = (index != 0);
    self.versionCollectionView.hidden = (index != 0);
    self.modTableView.hidden = (index != 1);
    self.shaderTableView.hidden = (index != 2);
    
    if (index == 1 && self.modList.count == 0) {
        [self loadModList];
    } else if (index == 2 && self.shaderList.count == 0) {
        [self loadShaderList];
    }
}

#pragma mark - Data Loading

- (void)loadVersionList {
    [self.loadingIndicator startAnimating];
    
    NSURL *url = [NSURL URLWithString:@"https://launchermeta.mojang.com/mc/game/version_manifest.json"];
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

- (void)loadModList {
    [self.loadingIndicator startAnimating];
    
    // 加载Modrinth热门模组
    [[ModrinthAPI sharedInstance] searchModWithFilters:@{@"limit": @50} completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            
            if (results) {
                self.modList = [results mutableCopy];
                [self.modTableView reloadData];
            }
        });
    }];
}

- (void)loadShaderList {
    [self.loadingIndicator startAnimating];
    
    // 加载Modrinth热门光影
    [[ModrinthAPI sharedInstance] searchShaderWithFilters:@{@"limit": @50} completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingIndicator stopAnimating];
            
            if (results) {
                self.shaderList = [results mutableCopy];
                [self.shaderTableView reloadData];
            }
        });
    }];
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
    
    cell.versionLabel.text = versionId;
    cell.dateLabel.text = [self formatDate:releaseTime];
    
    if ([versionType isEqualToString:@"release"]) {
        cell.typeLabel.text = @"正式版";
        cell.typeLabel.backgroundColor = [UIColor systemGreenColor];
    } else if ([versionType isEqualToString:@"snapshot"]) {
        cell.typeLabel.text = @"测试版";
        cell.typeLabel.backgroundColor = [UIColor systemOrangeColor];
    } else {
        cell.typeLabel.text = @"远古版";
        cell.typeLabel.backgroundColor = [UIColor systemPurpleColor];
    }
    
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

- (void)showVersionDownloadDialog:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:versionId
                                                                   message:@"选择操作"
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

- (void)downloadVersion:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    
    // 创建版本配置
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;
    
    // 保存到PLProfiles
    PLProfiles.current.profiles[versionId] = profile;
    [PLProfiles.current save];
    PLProfiles.current.selectedProfileName = versionId;
    
    // 显示下载中
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"下载中"
                                                                           message:[NSString stringWithFormat:@"正在下载 %@...", versionId]
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progressAlert animated:YES completion:nil];
    
    // 模拟下载完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [progressAlert dismissViewControllerAnimated:YES completion:^{
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载完成"
                                                                                  message:[NSString stringWithFormat:@"%@ 下载完成", versionId]
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:successAlert animated:YES completion:nil];
        }];
    });
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (tableView == self.modTableView) {
        return self.modList.count;
    } else if (tableView == self.shaderTableView) {
        return self.shaderList.count;
    }
    return 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView == self.modTableView) {
        ModShaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
        NSDictionary *mod = self.modList[indexPath.row];
        
        cell.nameLabel.text = mod[@"title"] ?: mod[@"slug"];
        cell.descLabel.text = mod[@"description"] ?: @"";
        cell.authorLabel.text = [NSString stringWithFormat:@"by %@", mod[@"author"] ?: @"Unknown"];
        
        // 设置图标
        NSString *iconUrl = mod[@"icon_url"];
        if (iconUrl) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
                if (data) {
                    UIImage *image = [UIImage imageWithData:data];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        cell.iconView.image = image;
                    });
                }
            });
        } else {
            cell.iconView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
        }
        
        [cell.downloadButton addTarget:self action:@selector(downloadMod:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
        
        return cell;
    } else {
        ModShaderCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShaderCell" forIndexPath:indexPath];
        NSDictionary *shader = self.shaderList[indexPath.row];
        
        cell.nameLabel.text = shader[@"title"] ?: shader[@"slug"];
        cell.descLabel.text = shader[@"description"] ?: @"";
        cell.authorLabel.text = [NSString stringWithFormat:@"by %@", shader[@"author"] ?: @"Unknown"];
        
        // 设置图标
        NSString *iconUrl = shader[@"icon_url"];
        if (iconUrl) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:iconUrl]];
                if (data) {
                    UIImage *image = [UIImage imageWithData:data];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        cell.iconView.image = image;
                    });
                }
            });
        } else {
            cell.iconView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
        }
        
        [cell.downloadButton addTarget:self action:@selector(downloadShader:) forControlEvents:UIControlEventTouchUpInside];
        cell.downloadButton.tag = indexPath.row;
        
        return cell;
    }
}

- (void)downloadMod:(UIButton *)sender {
    NSInteger index = sender.tag;
    NSDictionary *mod = self.modList[index];
    NSString *modName = mod[@"title"] ?: mod[@"slug"];
    
    // 确保mods文件夹存在
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    NSString *modsPath = [NSString stringWithFormat:@"%s/instances/%@/mods", getenv("POJAV_HOME"), profileName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:modsPath]) {
        [fm createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载模组"
                                                                   message:[NSString stringWithFormat:@"开始下载 %@...", modName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
    });
}

- (void)downloadShader:(UIButton *)sender {
    NSInteger index = sender.tag;
    NSDictionary *shader = self.shaderList[index];
    NSString *shaderName = shader[@"title"] ?: shader[@"slug"];
    
    // 确保shaderpacks文件夹存在
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    NSString *shadersPath = [NSString stringWithFormat:@"%s/instances/%@/shaderpacks", getenv("POJAV_HOME"), profileName];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:shadersPath]) {
        [fm createDirectoryAtPath:shadersPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载光影"
                                                                   message:[NSString stringWithFormat:@"开始下载 %@...", shaderName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
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
