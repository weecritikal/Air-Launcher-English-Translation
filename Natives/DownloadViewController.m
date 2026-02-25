#import "DownloadViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModService.h"
#import "ShaderService.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "VersionCardCell.h"  // 新增：导入独立的 VersionCardCell
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressViewController.h"
#import "ModItem.h"
#import "ModVersionViewController.h"
#import "ModVersion.h"

#include <sys/time.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>

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

@interface DownloadViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITableViewDataSource, UITableViewDelegate, ModVersionViewControllerDelegate>

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
    
    // 根据配置选择下载源
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
    
    // 格式化日期
    NSString *formattedDate = [self formatDate:releaseTime];
    
    // 使用新的配置方法
    [cell configureWithVersionId:versionId date:formattedDate type:versionType];
    
    return cell;
}

- (NSString *)formatDate:(NSString *)dateString {
    if (dateString.length >= 10) {
        return [dateString substringToIndex:10];
    }
    return dateString;
}

- (BOOL)isNetworkAvailable {
    // 使用 Reachability 检测网络状态
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
    BOOL isNetworkReachable = (isReachable && !needsConnection);
    
    return isNetworkReachable;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *version = self.filteredVersions[indexPath.row];
    [self showVersionDownloadDialog:version];
}

- (void)showVersionDownloadDialog:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    NSString *versionType = version[@"type"];
    
    // 格式化版本类型显示
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

- (void)downloadVersion:(NSDictionary *)version {
    // 检查网络状态
    if (![self isNetworkAvailable]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"网络不可用"
                                                                       message:@"请检查您的网络连接后重试"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *versionId = version[@"id"];
    
    // 创建版本配置
    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
    profile[@"name"] = versionId;
    profile[@"lastVersionId"] = versionId;
    profile[@"type"] = @"custom";
    profile[@"created"] = [NSDate date].description;
    
    // 使用 saveProfile:withName: 方法保存配置，避免直接操作不可变字典
    [PLProfiles.current saveProfile:profile withName:versionId];
    PLProfiles.current.selectedProfileName = versionId;
    
    // 显示下载进度对话框
    self.downloadingAlert = [UIAlertController alertControllerWithTitle:@"下载中"
                                                                message:@"正在准备下载..."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    
    __weak DownloadViewController *weakSelf = self;
    
    // 查看详情按钮
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
    
    // 取消按钮
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
    
    // 显示加载指示器
    [self.loadingIndicator startAnimating];
    
    // 创建真正的下载任务
    self.downloadTask = [MinecraftResourceDownloadTask new];
    self.downloadTask.maxRetryCount = 3; // 设置最大重试次数
    
    // 重试回调（使用上面已定义的 weakSelf）
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
            
            UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:@"下载失败"
                                                                                message:@"版本下载失败，请检查网络连接后重试"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            [errorAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:errorAlert animated:YES completion:nil];
        });
    };
    
    // 在后台线程执行下载
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.downloadTask downloadVersion:version];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // 监听下载进度
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
    
    // 更新文本进度
    NSInteger completedUnitCount = progress.totalUnitCount * progress.fractionCompleted;
    textProgress.completedUnitCount = completedUnitCount;
    
    // 计算下载速度和剩余时间
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
        // 更新进度显示
        if (self.progressVC) {
            // 如果已经显示了进度详情，不需要更新 alert
        } else if (self.downloadingAlert) {
            // 更新 alert 的消息，显示详细进度
            NSString *progressText = textProgress.localizedAdditionalDescription;
            if (!progressText || progressText.length == 0) {
                progressText = [NSString stringWithFormat:@"%.1f%%", progress.fractionCompleted * 100];
            }
            
            // 格式化下载速度
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
            
            // 格式化剩余时间
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
        
        // 检查是否完成
        if (progress.finished) {
            [self.downloadTask.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            
            // 重置静态变量
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
            
            // 显示下载完成提示
            UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载完成"
                                                                                  message:[NSString stringWithFormat:@"%@ 下载完成", self.downloadTask.metadata[@"id"] ?: @"版本"]
                                                                           preferredStyle:UIAlertControllerStyleAlert];
            [successAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:successAlert animated:YES completion:nil];
            
            self.downloadTask = nil;
        }
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
    
    // 创建ModItem用于版本选择
    ModItem *modItem = [[ModItem alloc] initWithOnlineData:mod];
    
    // 显示版本选择页面
    ModVersionViewController *versionVC = [[ModVersionViewController alloc] init];
    versionVC.modItem = modItem;
    versionVC.delegate = self;
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:versionVC];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - ModVersionViewControllerDelegate

- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    ModItem *itemToDownload = viewController.modItem;
    
    // 获取下载信息
    NSDictionary *primaryFile = version.primaryFile;
    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
        [self showSimpleAlertWithTitle:@"错误" message:@"未找到有效的下载链接。"];
        return;
    }
    
    // 设置下载URL和文件名
    itemToDownload.selectedVersionDownloadURL = primaryFile[@"url"];
    itemToDownload.fileName = primaryFile[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", itemToDownload.displayName];
    
    // 关闭版本选择页面
    [viewController dismissViewControllerAnimated:YES completion:^{
        // 开始下载
        [self startDownloadForModItem:itemToDownload];
    }];
}

- (void)startDownloadForModItem:(ModItem *)item {
    // 显示下载提示
    UIAlertController *downloadingAlert = [UIAlertController alertControllerWithTitle:@"正在下载"
                                                                              message:[NSString stringWithFormat:@"%@...", item.displayName]
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
    
    // 获取当前配置文件的名称
    NSString *profileName = PLProfiles.current.selectedProfileName ?: @"default";
    
    [[ModService sharedService] downloadMod:item toProfile:profileName completion:^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [downloadingAlert dismissViewControllerAnimated:YES completion:^{
                if (error) {
                    [self showSimpleAlertWithTitle:@"下载失败" message:error.localizedDescription];
                } else {
                    UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:@"下载成功"
                                                                                          message:[NSString stringWithFormat:@"%@ 已成功安装到 mods 文件夹。", item.displayName]
                                                                                   preferredStyle:UIAlertControllerStyleAlert];
                    [successAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:successAlert animated:YES completion:nil];
                }
            }];
        });
    }];
}

- (void)showSimpleAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
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
