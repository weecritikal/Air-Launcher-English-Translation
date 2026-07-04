#import "VersionManagerViewController.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Modern Tile Base Cell

@interface VMTileBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
- (void)setupViews;
@end

@implementation VMTileBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.layer.shadowOpacity = 0.15;
    self.layer.shadowRadius = 8;
    self.layer.masksToBounds = NO;
    
    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:self.contentContainer];
    
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

#pragma mark - Quick Action Tile Cell

@interface VMQuickActionCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation VMQuickActionCell

- (void)setupViews {
    [super setupViews];
    
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];
    
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    [self.contentContainer addSubview:self.titleLabel];
    
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.numberOfLines = 1;
    [self.contentContainer addSubview:self.subtitleLabel];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:16],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.widthAnchor constraintEqualToConstant:28],
        [self.iconView.heightAnchor constraintEqualToConstant:28],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:12],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-12]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = color;
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
}

@end

#pragma mark - Version Card Cell

@interface VMVersionCardCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UILabel *lastPlayedLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@property (nonatomic, strong) UILabel *isolatedBadge;
@end

@implementation VMVersionCardCell

- (void)setupViews {
    [super setupViews];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor labelColor];
    self.nameLabel.numberOfLines = 1;
    [self.contentContainer addSubview:self.nameLabel];

    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    [self.contentContainer addSubview:self.versionLabel];

    // FCL 风格：最后游玩时间小字（仅在有过游玩记录时显示）
    self.lastPlayedLabel = [[UILabel alloc] init];
    self.lastPlayedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lastPlayedLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    self.lastPlayedLabel.textColor = [UIColor tertiaryLabelColor];
    self.lastPlayedLabel.text = @"";
    [self.contentContainer addSubview:self.lastPlayedLabel];

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

    // FCL 风格：版本隔离徽章（仅当 gameDir != "." 时显示）
    self.isolatedBadge = [[UILabel alloc] init];
    self.isolatedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.isolatedBadge.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
    self.isolatedBadge.textColor = [UIColor whiteColor];
    self.isolatedBadge.backgroundColor = [UIColor systemTealColor];
    self.isolatedBadge.textAlignment = NSTextAlignmentCenter;
    self.isolatedBadge.layer.cornerRadius = 4;
    self.isolatedBadge.layer.masksToBounds = YES;
    self.isolatedBadge.text = @" 隔离 ";
    self.isolatedBadge.hidden = YES;
    [self.contentContainer addSubview:self.isolatedBadge];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconView.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconView.widthAnchor constraintEqualToConstant:36],
        [self.iconView.heightAnchor constraintEqualToConstant:36],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:12],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.selectedBadge.leadingAnchor constant:-8],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:4],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        // 最后游玩时间放在 versionLabel 下方，与 isolatedBadge 同行
        [self.lastPlayedLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.lastPlayedLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:2],
        [self.lastPlayedLabel.trailingAnchor constraintEqualToAnchor:self.isolatedBadge.leadingAnchor constant:-6],
        [self.isolatedBadge.centerYAnchor constraintEqualToAnchor:self.lastPlayedLabel.centerYAnchor],
        [self.isolatedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.isolatedBadge.heightAnchor constraintEqualToConstant:16],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.selectedBadge.centerYAnchor constraintEqualToAnchor:self.nameLabel.centerYAnchor],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:24],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:24],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithName:(NSString *)name version:(NSString *)version isSelected:(BOOL)isSelected isolated:(BOOL)isolated lastPlayed:(NSString *)lastPlayed {
    self.nameLabel.text = name;
    self.versionLabel.text = version ?: @"未知版本";
    self.selectedBadge.hidden = !isSelected;
    self.isolatedBadge.hidden = !isolated;
    self.lastPlayedLabel.text = lastPlayed.length > 0 ? lastPlayed : @"";

    // FCL 风格：根据 versionId 中的关键字识别加载器类型，显示对应图标和颜色
    NSString *lowerVersion = [version.lowercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    UIImage *icon = [UIImage systemImageNamed:@"cube.box.fill"];
    UIColor *iconColor = [UIColor systemBlueColor];
    if ([lowerVersion containsString:@"fabric"]) {
        icon = [UIImage systemImageNamed:@"wand.and.stars"];
        iconColor = [UIColor colorWithRed:0.85 green:0.55 blue:0.95 alpha:1.0];
    } else if ([lowerVersion containsString:@"quilt"]) {
        icon = [UIImage systemImageNamed:@"circle.hexagongrid.fill"];
        iconColor = [UIColor colorWithRed:0.95 green:0.55 blue:0.55 alpha:1.0];
    } else if ([lowerVersion containsString:@"neoforge"]) {
        icon = [UIImage systemImageNamed:@"hammer.fill"];
        iconColor = [UIColor colorWithRed:0.92 green:0.45 blue:0.30 alpha:1.0];
    } else if ([lowerVersion containsString:@"forge"]) {
        icon = [UIImage systemImageNamed:@"anvil.fill"];
        iconColor = [UIColor colorWithRed:0.70 green:0.50 blue:0.40 alpha:1.0];
    } else if ([lowerVersion containsString:@"optifine"] || [lowerVersion containsString:@"optifabric"]) {
        icon = [UIImage systemImageNamed:@"eye.fill"];
        iconColor = [UIColor systemOrangeColor];
    }
    self.iconView.image = icon;
    self.iconView.tintColor = iconColor;

    if (isSelected) {
        self.contentView.layer.borderColor = [UIColor systemGreenColor].CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else {
        self.contentView.layer.borderColor = [UIColor separatorColor].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
}

@end

#pragma mark - Header View

@interface VMSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation VMSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        self.titleLabel.textColor = [UIColor labelColor];
        [self addSubview:self.titleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}

@end

#pragma mark - View Controller

@interface VersionManagerViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<NSString *> *profileList;
@property (nonatomic, strong) NSString *selectedProfile;
@end

@implementation VersionManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"版本管理";
    self.view.backgroundColor = [UIColor clearColor];
    [self setupCollectionView];
    [self setupNavigationBar];
    [self setupLongPressGesture];
    [self loadProfiles];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"ReloadProfileList"
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// FCL 风格：导航栏右侧"+"按钮，点击进入下载/新建版本页面
- (void)setupNavigationBar {
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"plus"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(createNewVersion)];
    addButton.accessibilityLabel = @"新建版本";
    self.navigationItem.rightBarButtonItem = addButton;
}

/// FCL 风格：长按版本卡片弹出操作菜单（选择/编辑/删除）
- (void)setupLongPressGesture {
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5;
    [self.collectionView addGestureRecognizer:longPress];
}

- (void)createNewVersion {
    // 通知 LauncherRootViewController/LauncherCardLayoutViewController 切换到下载页面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath || indexPath.section == 0) return;
    if (indexPath.item >= (NSInteger)self.profileList.count) return;
    [self showProfileActions:self.profileList[indexPath.item]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self.collectionView reloadData];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)profileChanged {
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self.collectionView reloadData];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

#pragma mark - Setup

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    
    [self.collectionView registerClass:[VMQuickActionCell class] forCellWithReuseIdentifier:@"QuickActionCell"];
    [self.collectionView registerClass:[VMVersionCardCell class] forCellWithReuseIdentifier:@"VersionCell"];
    [self.collectionView registerClass:[VMSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];
    
    [self.view addSubview:self.collectionView];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 700;
        
        // 通用 header size（FCL 风格：两个 section 都带标题）
        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension absoluteDimension:44]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
        
        if (sectionIndex == 0) {
            // Quick actions section - 6 items，3 列 2 行（FCL 风格：游戏目录/Mod/光影/资源包/数据包/世界）
            NSInteger columnCount = 3;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0 / columnCount]
                                                                              heightDimension:[NSCollectionLayoutDimension absoluteDimension:100]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(6, 6, 6, 6);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:100]];
            // 用 subitem:count: 确保 group 包含 columnCount 个 item，section 会自动重复 group 渲染 2 行
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitem:item count:columnCount];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(8, 14, 8, 14);
            section.boundarySupplementaryItems = @[header];
            return section;
        } else {
            // 版本卡片：增加 lastPlayed/isolatedBadge 行后需要更高空间
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:isiPad ? 0.5 : 1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension absoluteDimension:86]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:86]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 14, 20, 14);

            section.boundarySupplementaryItems = @[header];
            return section;
        }
    }];
}

#pragma mark - Data

- (void)loadProfiles {
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *key in profiles.allKeys) {
        [list addObject:key];
    }
    self.profileList = [list sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        return [obj2 compare:obj1];
    }];
    self.selectedProfile = PLProfiles.current.selectedProfileName;
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section == 0) return 6;
    return self.profileList.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        VMQuickActionCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"QuickActionCell" forIndexPath:indexPath];

        switch (indexPath.item) {
            case 0:
                [cell configureWithIcon:@"folder.fill" title:@"游戏目录" subtitle:getPrefObject(@"general.game_directory") color:[UIColor systemBlueColor]];
                break;
            case 1:
                [cell configureWithIcon:@"puzzlepiece.extension.fill" title:@"Mod 管理" subtitle:@"管理已安装的 Mod" color:[UIColor systemOrangeColor]];
                break;
            case 2:
                [cell configureWithIcon:@"paintbrush.fill" title:@"光影管理" subtitle:@"管理光影包" color:[UIColor systemPurpleColor]];
                break;
            case 3:
                [cell configureWithIcon:@"shippingbox.fill" title:@"资源包管理" subtitle:@"管理资源包" color:[UIColor systemGreenColor]];
                break;
            case 4:
                [cell configureWithIcon:@"doc.text.fill" title:@"数据包管理" subtitle:@"管理数据包" color:[UIColor systemPinkColor]];
                break;
            case 5:
                [cell configureWithIcon:@"globe" title:@"世界管理" subtitle:@"管理存档" color:[UIColor systemTealColor]];
                break;
        }
        return cell;
    } else {
        VMVersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCell" forIndexPath:indexPath];

        NSString *profileName = self.profileList[indexPath.item];
        NSDictionary *profile = PLProfiles.current.profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"未知版本";
        BOOL isSelected = [profileName isEqualToString:self.selectedProfile];
        // FCL 风格：gameDir != "." 表示该 profile 启用了版本隔离
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        // 最后游玩时间（PLProfiles 在启动游戏时写入 lastPlayed 时间戳）
        NSString *lastPlayed = [self formatLastPlayed:profile[@"lastPlayed"]];

        [cell configureWithName:profileName version:versionId isSelected:isSelected isolated:isolated lastPlayed:lastPlayed];
        return cell;
    }
}

/// 将 lastPlayed 时间戳（NSNumber/NSString）格式化为"最后游玩：xxx"
- (NSString *)formatLastPlayed:(id)lastPlayedRaw {
    if (!lastPlayedRaw) return @"";
    NSTimeInterval ts;
    if ([lastPlayedRaw isKindOfClass:[NSNumber class]]) {
        ts = [lastPlayedRaw doubleValue];
    } else if ([lastPlayedRaw isKindOfClass:[NSString class]]) {
        ts = [(NSString *)lastPlayedRaw doubleValue];
    } else {
        return @"";
    }
    if (ts <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale currentLocale];
    fmt.doesRelativeDateFormatting = YES;
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:@"最后游玩：%@", [fmt stringFromDate:date]];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (kind == UICollectionElementKindSectionHeader) {
        VMSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
        if (indexPath.section == 0) {
            header.titleLabel.text = @"快速操作";
        } else {
            header.titleLabel.text = @"已安装的版本";
        }
        return header;
    }
    return [UICollectionReusableView new];
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        switch (indexPath.item) {
            case 0: [self openGameDirectory]; break;
            case 1: [self openModsManager]; break;
            case 2: [self openShadersManager]; break;
            case 3: [self openResourcePacksManager]; break;
            case 4: [self openDataPacksManager]; break;
            case 5: [self openWorldsManager]; break;
        }
    } else {
        // FCL 风格：点击未选中版本 → 立即选中；点击已选中版本 → 弹出编辑/删除菜单
        NSString *profileName = self.profileList[indexPath.item];
        BOOL isSelected = [profileName isEqualToString:self.selectedProfile];
        if (!isSelected) {
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
            // 选中后立即刷新以更新选中徽章
            [self loadProfiles];
            [self.collectionView reloadData];
        } else {
            // 已选中的版本：点击则打开编辑/删除菜单
            [self showProfileActions:profileName];
        }
    }
}

#pragma mark - Actions

- (void)openGameDirectory {
    LauncherPrefGameDirViewController *vc = [[LauncherPrefGameDirViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openModsManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ModsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = DataPacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    if (!self.selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = WorldsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showProfileActions:(NSString *)profileName {
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    BOOL isSelected = [profileName isEqualToString:self.selectedProfile];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:profileName
                                                                   message:profile[@"lastVersionId"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    if (!isSelected) {
        [alert addAction:[UIAlertAction actionWithTitle:@"选择此版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            PLProfiles.current.selectedProfileName = profileName;
            [PLProfiles.current save];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
            [self loadProfiles];
            [self.collectionView reloadData];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"编辑配置" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self editProfile:profileName];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteProfile:profileName];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)editProfile:(NSString *)profileName {
    // 使用 ProfileSettingsViewController（合并后的统一 Edit Profile 页面）
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)deleteProfile:(NSString *)profileName {
    if (self.profileList.count <= 1) {
        [self showAlert:@"至少需要保留一个版本配置"];
        return;
    }
    
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认删除"
                                                                     message:[NSString stringWithFormat:@"确定要删除 \"%@\" 吗？", profileName]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    
    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
        }
        [PLProfiles.current save];
        [self loadProfiles];
        [self.collectionView reloadData];
    }]];
    
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end