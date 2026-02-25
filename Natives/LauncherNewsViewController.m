#import "LauncherNewsViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "ios_uikit_bridge.h"
#import <QuartzCore/QuartzCore.h>

// MARK: - Modern Tile Base Cell

@interface NewsBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *contentContainer;

- (void)setupViews;
@end

@implementation NewsBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 磁贴阴影
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.layer.shadowOpacity = 0.1;
    self.layer.shadowRadius = 8;
    self.layer.masksToBounds = NO;
    
    // 模糊背景容器
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    self.blurView.frame = self.contentView.bounds;
    self.blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.blurView.layer.cornerRadius = 16;
    self.blurView.layer.masksToBounds = YES;
    // 边框增加质感
    self.blurView.layer.borderWidth = 0.5;
    self.blurView.layer.borderColor = [UIColor separatorColor].CGColor;
    
    [self.contentView addSubview:self.blurView];
    
    // 内容容器
    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:self.contentContainer];
}

// 非线性按压动画
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:nil];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

// MARK: - Skin Profile Cell

@interface SkinProfileCell : NewsBaseCell
@property (nonatomic, strong) UIImageView *skinImageView;
@property (nonatomic, strong) UILabel *welcomeLabel;
@property (nonatomic, strong) UILabel *subLabel;
@end

@implementation SkinProfileCell

- (void)setupViews {
    [super setupViews];
    
    // 皮肤预览
    self.skinImageView = [[UIImageView alloc] init];
    self.skinImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.skinImageView.contentMode = UIViewContentModeScaleAspectFit;
    // 增加一点阴影让皮肤立体
    self.skinImageView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.skinImageView.layer.shadowOffset = CGSizeMake(0, 2);
    self.skinImageView.layer.shadowOpacity = 0.3;
    self.skinImageView.layer.shadowRadius = 4;
    
    [self.contentContainer addSubview:self.skinImageView];
    
    // 欢迎文本
    self.welcomeLabel = [[UILabel alloc] init];
    self.welcomeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.welcomeLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold]; // 使用 boldSystemFont 的现代替代
    self.welcomeLabel.textColor = [UIColor labelColor];
    self.welcomeLabel.numberOfLines = 1;
    [self.contentContainer addSubview:self.welcomeLabel];
    
    // 副标题
    self.subLabel = [[UILabel alloc] init];
    self.subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.subLabel.textColor = [UIColor secondaryLabelColor];
    self.subLabel.text = @"准备就绪";
    [self.contentContainer addSubview:self.subLabel];
    
    // 布局约束
    [NSLayoutConstraint activateConstraints:@[
        [self.skinImageView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.skinImageView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:20],
        [self.skinImageView.heightAnchor constraintEqualToAnchor:self.contentContainer.heightAnchor multiplier:0.8],
        [self.skinImageView.widthAnchor constraintEqualToAnchor:self.skinImageView.heightAnchor multiplier:0.6], // 皮肤比例
        
        [self.welcomeLabel.leadingAnchor constraintEqualToAnchor:self.skinImageView.trailingAnchor constant:20],
        [self.welcomeLabel.topAnchor constraintEqualToAnchor:self.skinImageView.topAnchor constant:10],
        [self.welcomeLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-20],
        
        [self.subLabel.leadingAnchor constraintEqualToAnchor:self.welcomeLabel.leadingAnchor],
        [self.subLabel.topAnchor constraintEqualToAnchor:self.welcomeLabel.bottomAnchor constant:4],
        [self.subLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-20]
    ]];
}

@end

// MARK: - Info Tile Cell

@interface InfoTileCell : NewsBaseCell
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UIImageView *iconView;
@end

@implementation InfoTileCell

- (void)setupViews {
    [super setupViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.tintColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconView];
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.titleLabel.textColor = [UIColor secondaryLabelColor];
    [self.contentContainer addSubview:self.titleLabel];
    
    self.valueLabel = [[UILabel alloc] init];
    self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.valueLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.valueLabel.textColor = [UIColor labelColor];
    self.valueLabel.numberOfLines = 0;
    [self.contentContainer addSubview:self.valueLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:16],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:24],
        [self.iconView.heightAnchor constraintEqualToConstant:24],
        
        [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.iconView.centerYAnchor],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:8],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        
        [self.valueLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:8],
        [self.valueLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.valueLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.valueLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-16]
    ]];
}

@end

// MARK: - View Controller

@interface LauncherNewsViewController () <UICollectionViewDataSource, UICollectionViewDelegate>

@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSString *latestRelease;
@property (nonatomic, strong) NSString *latestSnapshot;
@property (nonatomic, strong) NSString *currentUsername;
@property (nonatomic, strong) UIImage *currentSkin;
@property (nonatomic, assign) BOOL isLoadingVersions;

@end

@implementation LauncherNewsViewController

- (id)init {
    self = [super init];
    if (self) {
        self.title = @"主页";
        self.latestRelease = @"检测中...";
        self.latestSnapshot = @"检测中...";
        self.isLoadingVersions = YES;
    }
    return self;
}

- (NSString *)imageName {
    return @"MenuNews";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    self.navigationController.navigationBarHidden = YES;
    
    [self setupCollectionView];
    [self updateSkinDisplay];
    [self checkMinecraftVersions];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"AccountChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    
    [self.collectionView registerClass:[SkinProfileCell class] forCellWithReuseIdentifier:@"SkinCell"];
    [self.collectionView registerClass:[InfoTileCell class] forCellWithReuseIdentifier:@"InfoCell"];
    
    [self.view addSubview:self.collectionView];
}

- (UICollectionViewLayout *)createLayout {
    // 现代 Compositional Layout
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 600; // 简单判断
        
        NSCollectionLayoutSection *section;
        
        if (sectionIndex == 0) {
            // 用户资料 - 大横幅
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1.0]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            
            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:160]]; // 固定高度
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
            
            section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(20, 20, 10, 20);
            
        } else {
            // 版本信息 - 磁贴网格
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:isiPad ? 0.5 : 1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension fractionalHeightDimension:1.0]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(0, isiPad ? 10 : 0, 0, isiPad ? 10 : 0);
            
            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:110]];
            
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
            if (!isiPad) {
                group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:10];
            }
            
            section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(10, 20, 20, 20);
            section.interGroupSpacing = 10;
        }
        
        return section;
    }];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section == 0) return 1; // Skin
    return 2; // Release & Snapshot
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        SkinProfileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"SkinCell" forIndexPath:indexPath];
        
        cell.welcomeLabel.text = @"欢迎回来";
        cell.skinImageView.image = self.currentSkin ?: [UIImage systemImageNamed:@"person.fill"];
        cell.subLabel.text = @"准备好开始游戏了吗？";
        
        return cell;
    } else {
        InfoTileCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"InfoCell" forIndexPath:indexPath];
        
        if (indexPath.item == 0) {
            cell.titleLabel.text = @"最新正式版";
            cell.valueLabel.text = self.latestRelease;
            cell.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
            cell.iconView.tintColor = [UIColor systemGreenColor];
        } else {
            cell.titleLabel.text = @"最新快照";
            cell.valueLabel.text = self.latestSnapshot;
            cell.iconView.image = [UIImage systemImageNamed:@"ant.fill"]; // 或者是 hammer.fill
            cell.iconView.tintColor = [UIColor systemOrangeColor];
        }
        
        return cell;
    }
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    // 点击反馈，可以在这里添加跳转逻辑
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    
    // 如果是版本信息，可以尝试刷新
    if (indexPath.section == 1) {
        [self checkMinecraftVersions];
    }
}

#pragma mark - Logic

- (void)updateSkinDisplay {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.currentUsername = username;
        } else {
            self.currentUsername = @"玩家";
        }
        
        NSString *uuid = currentAuth.authData[@"uuid"];
        if (uuid) {
            [self loadSkinForUUID:uuid];
        } else {
            [self loadDefaultSkin];
        }
    } else {
        self.currentUsername = @"未登录";
        [self loadDefaultSkin];
    }
    
    [self.collectionView reloadData];
}

- (void)loadSkinForUUID:(NSString *)uuid {
    NSString *skinURL = [NSString stringWithFormat:@"http://111.170.35.224:3000/renders/body/%@?overlay", uuid];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:skinURL]];
        UIImage *skinImage = nil;
        if (imageData) {
            skinImage = [UIImage imageWithData:imageData];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (skinImage) {
                self.currentSkin = skinImage;
            } else {
                [self loadDefaultSkin]; // Fallback inside async
                return;
            }
            [self.collectionView reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
        });
    });
}

- (void)loadDefaultSkin {
    NSString *steveSkinURL = @"http://111.170.35.224:3000/renders/body/8667ba71b85a4004af54457a9734eed7?overlay";
    
    // 如果当前已经是默认皮肤，避免重复加载 (简单判断 image 是否为空)
    if (self.currentSkin != nil && [self.currentUsername isEqualToString:@"未登录"]) {
         // Maybe check logic, but re-loading is safer
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:steveSkinURL]];
        UIImage *steveSkin = nil;
        if (imageData) {
            steveSkin = [UIImage imageWithData:imageData];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (steveSkin) {
                self.currentSkin = steveSkin;
            } else {
                self.currentSkin = [UIImage systemImageNamed:@"person.fill"];
            }
            [self.collectionView reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
        });
    });
}

- (void)checkMinecraftVersions {
    if (self.isLoadingVersions) {
        // Already loading or initial state
    }
    self.isLoadingVersions = YES;
    self.latestRelease = @"检测中...";
    self.latestSnapshot = @"检测中...";
    [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:1]];
    
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
            self.isLoadingVersions = NO;
            
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json) {
                    NSDictionary *latest = json[@"latest"];
                    self.latestRelease = latest[@"release"] ?: @"未知";
                    self.latestSnapshot = latest[@"snapshot"] ?: @"未知";
                } else {
                    self.latestRelease = @"检测失败";
                    self.latestSnapshot = @"检测失败";
                }
            } else {
                self.latestRelease = @"网络错误";
                self.latestSnapshot = @"网络错误";
            }
            [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:1]];
        });
    }];
    [task resume];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
