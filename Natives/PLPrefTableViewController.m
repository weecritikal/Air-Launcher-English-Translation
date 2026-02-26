#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "DBNumberedSlider.h"
#import "LauncherNavigationController.h"
#import "LauncherMenuViewController.h"
#import "LauncherPreferences.h"
#import "PLPrefTableViewController.h"
#import "PLCardSettingCell.h"
#import "UIKit+hook.h"

#import "ios_uikit_bridge.h"
#import "utils.h"
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Modern Card Cell

// 现代化卡片 Cell
@interface PLModernCardCell : UICollectionViewCell
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *contentContainer;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UIView *accessoryContainer;
@property (nonatomic, strong) UIView *iconBg;
@end

@implementation PLModernCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 卡片阴影
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
    self.blurView.layer.borderWidth = 0.5;
    self.blurView.layer.borderColor = [UIColor separatorColor].CGColor;
    [self.contentView addSubview:self.blurView];
    
    // 内容容器
    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.blurView.contentView addSubview:self.contentContainer];
    
    // 图标背景
    self.iconBg = [[UIView alloc] init];
    self.iconBg.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.iconBg.layer.cornerRadius = 10;
    self.iconBg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.iconBg];
    
    // 图标
    self.iconImageView = [[UIImageView alloc] init];
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconImageView.tintColor = [UIColor systemBlueColor];
    self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.iconBg addSubview:self.iconImageView];
    
    // 标题
    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.titleLabel];
    
    // 副标题
    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.numberOfLines = 2;
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.subtitleLabel];
    
    // 详情标签
    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.detailLabel.textColor = [UIColor tertiaryLabelColor];
    self.detailLabel.textAlignment = NSTextAlignmentRight;
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.detailLabel];
    
    // 附件容器
    self.accessoryContainer = [[UIView alloc] init];
    self.accessoryContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentContainer addSubview:self.accessoryContainer];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [self.iconBg.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:16],
        [self.iconBg.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.iconBg.widthAnchor constraintEqualToConstant:36],
        [self.iconBg.heightAnchor constraintEqualToConstant:36],
        
        [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.iconBg.centerXAnchor],
        [self.iconImageView.centerYAnchor constraintEqualToAnchor:self.iconBg.centerYAnchor],
        [self.iconImageView.widthAnchor constraintEqualToConstant:24],
        [self.iconImageView.heightAnchor constraintEqualToConstant:24],
        
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconBg.trailingAnchor constant:12],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:14],
        [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.detailLabel.leadingAnchor constant:-8],
        
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.accessoryContainer.leadingAnchor constant:-8],
        
        [self.detailLabel.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:self.accessoryContainer.leadingAnchor constant:-8],
        
        [self.accessoryContainer.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-16],
        [self.accessoryContainer.centerYAnchor constraintEqualToAnchor:self.contentContainer.centerYAnchor],
        [self.accessoryContainer.widthAnchor constraintGreaterThanOrEqualToConstant:60],
        [self.accessoryContainer.heightAnchor constraintEqualToConstant:32]
    ]];
}

- (void)configureWithTitle:(NSString *)title 
                   subtitle:(NSString *)subtitle 
                       icon:(NSString *)iconName 
                     detail:(NSString *)detail 
                destructive:(BOOL)destructive {
    
    self.titleLabel.text = title;
    self.titleLabel.textColor = destructive ? [UIColor systemRedColor] : [UIColor labelColor];
    
    self.subtitleLabel.text = subtitle;
    self.subtitleLabel.hidden = !subtitle || subtitle.length == 0;
    
    self.detailLabel.text = detail;
    self.detailLabel.hidden = !detail || detail.length == 0;
    
    if (iconName && iconName.length > 0) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightMedium];
        self.iconImageView.image = [UIImage systemImageNamed:iconName withConfiguration:config];
        self.iconImageView.hidden = NO;
    } else {
        self.iconImageView.hidden = YES;
    }
    
    self.iconImageView.tintColor = destructive ? [UIColor systemRedColor] : [UIColor systemBlueColor];
}

- (void)setCustomAccessoryView:(UIView *)view {
    for (UIView *subview in self.accessoryContainer.subviews) {
        [subview removeFromSuperview];
    }
    
    if (view) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.accessoryContainer addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.centerXAnchor constraintEqualToAnchor:self.accessoryContainer.centerXAnchor],
            [view.centerYAnchor constraintEqualToAnchor:self.accessoryContainer.centerYAnchor],
            [view.widthAnchor constraintLessThanOrEqualToAnchor:self.accessoryContainer.widthAnchor],
            [view.heightAnchor constraintLessThanOrEqualToAnchor:self.accessoryContainer.heightAnchor]
        ]];
    }
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.titleLabel.text = nil;
    self.subtitleLabel.text = nil;
    self.detailLabel.text = nil;
    self.iconImageView.image = nil;
    self.iconImageView.hidden = NO;
    
    for (UIView *subview in self.accessoryContainer.subviews) {
        [subview removeFromSuperview];
    }
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

#pragma mark - Section Header View

@interface PLCardSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation PLCardSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [self addSubview:_titleLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
        ]];
    }
    return self;
}

@end

#pragma mark - PLPrefTableViewController

@interface PLPrefTableViewController()<UIContextMenuInteractionDelegate> {
    UIScrollView *_currentScrollView;
}
@property(nonatomic) UIMenu* currentMenu;
@property(nonatomic) UIBarButtonItem *helpBtn;
@property(nonatomic) UIView *layoutSwitcherContainer;

// 列表模式
@property(nonatomic, strong) UITableView *tableView;

// 卡片模式
@property(nonatomic, strong) UICollectionView *collectionView;

@end

@implementation PLPrefTableViewController

- (id)init {
    self = [super init];
    [self initViewCreation];
    // 从偏好设置加载布局模式
    _layoutMode = (PLSettingsLayoutMode)[[NSUserDefaults standardUserDefaults] integerForKey:@"settings_layout_mode"];
    return self;
}

- (UIScrollView *)scrollView {
    return _currentScrollView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    [self setupMainView];
    
    if (self.prefSections) {
        self.prefSectionsVisibility = [[NSMutableArray<NSNumber *> alloc] initWithCapacity:self.prefSections.count];
        for (int i = 0; i < self.prefSections.count; i++) {
            [self.prefSectionsVisibility addObject:@(self.prefSectionsVisible)];
        }
    } else {
        self.prefSectionsVisibility = (id)@[@YES];
    }
}

- (void)setupMainView {
    // 清除旧的视图
    for (UIView *subview in self.view.subviews) {
        [subview removeFromSuperview];
    }
    
    if (self.layoutMode == PLSettingsLayoutModeCard) {
        [self setupCollectionView];
        _currentScrollView = _collectionView;
    } else {
        [self setupTableView];
        _currentScrollView = _tableView;
    }
    
    // 设置布局切换器（如果需要）
    if (self.showLayoutSwitcher) {
        [self setupLayoutSwitcher];
    }
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];
}

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createCardLayout];
    _collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    _collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    
    [_collectionView registerClass:[PLModernCardCell class] forCellWithReuseIdentifier:@"CardCell"];
    [_collectionView registerClass:[PLCardSectionHeaderView class] forSupplementaryViewOfKind:UICollectionView.elementKindSectionHeader withReuseIdentifier:@"SectionHeader"];
    
    [self.view addSubview:_collectionView];
}

- (UICollectionViewLayout *)createCardLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 600;
        
        // 卡片项
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:isiPad ? 0.5 : 1.0]
                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:70]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
        item.contentInsets = NSDirectionalEdgeInsetsMake(0, isiPad ? 8 : 0, 0, isiPad ? 8 : 0);
        
        NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                               heightDimension:[NSCollectionLayoutDimension absoluteDimension:70]];
        
        NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];
        
        NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
        section.contentInsets = NSDirectionalEdgeInsetsMake(8, 16, 16, 16);
        section.interGroupSpacing = 10;
        
        // Section Header
        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                           heightDimension:[NSCollectionLayoutDimension absoluteDimension:40]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize
                                                                                                                                         elementKind:UICollectionView.elementKindSectionHeader
                                                                                                                                           alignment:NSRectAlignmentTop];
        section.boundarySupplementaryItems = @[header];
        
        return section;
    }];
}

- (void)setupLayoutSwitcher {
    self.layoutSwitcher = [[UISegmentedControl alloc] initWithItems:@[@"列表", @"卡片"]];
    self.layoutSwitcher.selectedSegmentIndex = self.layoutMode;
    [self.layoutSwitcher addTarget:self action:@selector(layoutModeChanged:) forControlEvents:UIControlEventValueChanged];
    
    // 创建切换器容器
    self.layoutSwitcherContainer = [[UIView alloc] init];
    self.layoutSwitcherContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.layoutSwitcherContainer];
    
    // 模糊背景
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.layer.cornerRadius = 12;
    blurView.layer.masksToBounds = YES;
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.layoutSwitcherContainer addSubview:blurView];
    
    self.layoutSwitcher.translatesAutoresizingMaskIntoConstraints = NO;
    [blurView.contentView addSubview:self.layoutSwitcher];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.layoutSwitcherContainer.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.layoutSwitcherContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.layoutSwitcherContainer.widthAnchor constraintEqualToConstant:200],
        [self.layoutSwitcherContainer.heightAnchor constraintEqualToConstant:44],
        
        [blurView.topAnchor constraintEqualToAnchor:self.layoutSwitcherContainer.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:self.layoutSwitcherContainer.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:self.layoutSwitcherContainer.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:self.layoutSwitcherContainer.bottomAnchor],
        
        [self.layoutSwitcher.topAnchor constraintEqualToAnchor:blurView.contentView.topAnchor constant:4],
        [self.layoutSwitcher.leadingAnchor constraintEqualToAnchor:blurView.contentView.leadingAnchor constant:4],
        [self.layoutSwitcher.trailingAnchor constraintEqualToAnchor:blurView.contentView.trailingAnchor constant:-4],
        [self.layoutSwitcher.bottomAnchor constraintEqualToAnchor:blurView.contentView.bottomAnchor constant:-4]
    ]];
    
    // 调整 scrollView 的 contentInset
    if (_currentScrollView) {
        _currentScrollView.contentInset = UIEdgeInsetsMake(52, 0, 0, 0);
    }
}

- (void)layoutModeChanged:(UISegmentedControl *)sender {
    PLSettingsLayoutMode newMode = (PLSettingsLayoutMode)sender.selectedSegmentIndex;
    if (newMode != self.layoutMode) {
        self.layoutMode = newMode;
        [self saveLayoutPreference];
        
        // 平滑切换动画
        [UIView transitionWithView:self.view
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [self setupMainView];
                            if (self.showLayoutSwitcher) {
                                [self setupLayoutSwitcher];
                            }
                        }
                        completion:nil];
    }
}

- (void)saveLayoutPreference {
    [[NSUserDefaults standardUserDefaults] setInteger:self.layoutMode forKey:@"settings_layout_mode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (UIBarButtonItem *)drawAccountButton {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 40, 40);
    button.layer.cornerRadius = 20;
    button.layer.masksToBounds = YES;
    button.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
        }
        [button setTitle:username ?: @"?" forState:UIControlStateNormal];
        
        NSString *avatarURL = currentAuth.authData[@"profilePicURL"];
        if (avatarURL) {
            avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                if (imageData) {
                    UIImage *image = [UIImage imageWithData:imageData];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [button setImage:image forState:UIControlStateNormal];
                        [button setTitle:@"" forState:UIControlStateNormal];
                    });
                }
            });
        }
    } else {
        [button setImage:[UIImage systemImageNamed:@"person.circle"] forState:UIControlStateNormal];
        button.tintColor = [UIColor systemGrayColor];
    }
    
    [button addTarget:self action:@selector(selectAccount:) forControlEvents:UIControlEventTouchUpInside];
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}

- (void)selectAccount:(UIButton *)sender {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    vc.whenItemSelected = ^void() {
        [self viewWillAppear:NO];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (UIBarButtonItem *)drawHelpButton {
    if (!self.helpBtn) {
        self.helpBtn = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"questionmark.circle"] style:UIBarButtonItemStyleDone target:self action:@selector(toggleDetailVisibility)];
    }
    return self.helpBtn;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    if (self.hasDetail && self.navigationController) {
        self.navigationItem.rightBarButtonItems = @[[self drawAccountButton], [self drawHelpButton]];
    }

    // 刷新子面板单元格
    if (self.layoutMode == PLSettingsLayoutModeClassic && _tableView) {
        NSMutableArray *indexPaths = [[NSMutableArray alloc] init];
        for (int section = 0; section < self.prefContents.count; section++) {
            if (!self.prefSectionsVisibility[section].boolValue) {
                continue;
            }
            for (int row = 0; row < self.prefContents[section].count; row++) {
                if (self.prefContents[section][row][@"type"] == self.typeChildPane) {
                    [indexPaths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
                }
            }
        }
        [_tableView reloadRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
    } else if (_collectionView) {
        [_collectionView reloadData];
    }
}

#pragma mark - UITableViewDataSource (Classic Mode)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.prefSectionsVisibility.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.prefSectionsVisibility[section].boolValue) {
        return self.prefContents[section].count;
    }
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    
    NSString *cellID;
    UITableViewCellStyle cellStyle;
    if (item[@"type"] == self.typeChildPane || item[@"type"] == self.typePickField) {
        cellID = @"cellValue1";
        cellStyle = UITableViewCellStyleValue1;
    } else {
        cellID = @"cellSubtitle";
        cellStyle = UITableViewCellStyleSubtitle;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:cellStyle reuseIdentifier:cellID];
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.textColor = nil;
    cell.detailTextLabel.text = nil;

    NSString *key = item[@"key"];
    if (indexPath.row == 0 && self.prefSections) {
        key = self.prefSections[indexPath.section];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.textLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", key]), nil);
    } else {
        CreateView createView = item[@"type"];
        createView(cell, self.prefSections[indexPath.section], key, item);
        if (cell.accessoryView) {
            objc_setAssociatedObject(cell.accessoryView, @"section", self.prefSections[indexPath.section], OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"key", key, OBJC_ASSOCIATION_ASSIGN);
            objc_setAssociatedObject(cell.accessoryView, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        }
        cell.textLabel.text = localize((item[@"title"] ? item[@"title"] :
            [NSString stringWithFormat:@"preference.title.%@", key]), nil);
    }

    BOOL destructive = [item[@"destructive"] boolValue];
    cell.imageView.tintColor = destructive ? UIColor.systemRedColor : nil;
    cell.imageView.image = [UIImage systemImageNamed:item[@"icon"]];
    
    if (cellStyle != UITableViewCellStyleValue1) {
        cell.detailTextLabel.text = nil;
        if ([item[@"hasDetail"] boolValue] && self.prefDetailVisible) {
            cell.detailTextLabel.text = localize(([NSString stringWithFormat:@"preference.detail.%@", key]), nil);
        }
    }

    BOOL(^checkEnable)(void) = item[@"enableCondition"];
    cell.userInteractionEnabled = !checkEnable || checkEnable();
    cell.textLabel.enabled = cell.detailTextLabel.enabled = cell.userInteractionEnabled;
    [(id)cell.accessoryView setEnabled:cell.userInteractionEnabled];

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    
    if (indexPath.row == 0 && self.prefSections) {
        self.prefSectionsVisibility[indexPath.section] = @(![self.prefSectionsVisibility[indexPath.section] boolValue]);
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:indexPath.section] withRowAnimation:UITableViewRowAnimationFade];
        return;
    }

    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];

    if (item[@"type"] == self.typeButton) {
        [self tableView:tableView invokeActionWithPromptAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typeChildPane) {
        [self tableView:tableView openChildPaneAtIndexPath:indexPath];
        return;
    } else if (item[@"type"] == self.typePickField) {
        [self tableView:tableView openPickerAtIndexPath:indexPath];
        return;
    } else if (realUIIdiom != UIUserInterfaceIdiomTV) {
        return;
    }

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (item[@"type"] == self.typeSwitch) {
        UISwitch *view = (id)cell.accessoryView;
        view.on = !view.isOn;
        [view sendActionsForControlEvents:UIControlEventValueChanged];
    }
}

#pragma mark - UICollectionViewDataSource (Card Mode)

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return self.prefSections.count ?: 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (self.prefSectionsVisibility[section].boolValue) {
        return self.prefContents[section].count;
    }
    return 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    PLModernCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"CardCell" forIndexPath:indexPath];
    
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    NSString *key = item[@"key"];
    NSString *section = self.prefSections[indexPath.section];
    
    NSString *title = localize((item[@"title"] ? item[@"title"] :
        [NSString stringWithFormat:@"preference.title.%@", key]), nil);
    
    NSString *subtitle = nil;
    if ([item[@"hasDetail"] boolValue] && self.prefDetailVisible) {
        subtitle = localize(([NSString stringWithFormat:@"preference.detail.%@", key]), nil);
    }
    
    BOOL destructive = [item[@"destructive"] boolValue];
    
    // 获取当前值显示
    NSString *detailText = nil;
    if (item[@"type"] == self.typePickField || item[@"type"] == self.typeChildPane) {
        id value = self.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            detailText = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            detailText = [value boolValue] ? @"ON" : @"OFF";
        } else if (value) {
            detailText = [value description];
        }
    }
    
    [cell configureWithTitle:title subtitle:subtitle icon:item[@"icon"] detail:detailText destructive:destructive];
    
    // 配置附件视图
    if (item[@"type"] == self.typeSwitch) {
        UISwitch *sw = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [sw setOn:[self.getPreference(section, key) boolValue] animated:NO];
        } else {
            [sw setOn:[self.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(sw, @"section", section, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(sw, @"key", key, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(sw, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        [cell setCustomAccessoryView:sw];
    } else if (item[@"type"] == self.typeSlider) {
        DBNumberedSlider *slider = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(0, 0, 100, 30)];
        slider.minimumValue = [item[@"min"] intValue];
        slider.maximumValue = [item[@"max"] intValue];
        slider.value = [self.getPreference(section, key) intValue];
        slider.continuous = YES;
        [slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(slider, @"section", section, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(slider, @"key", key, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(slider, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        [cell setCustomAccessoryView:slider];
    } else if (item[@"type"] == self.typeTextField) {
        UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 100, 30)];
        textField.textAlignment = NSTextAlignmentRight;
        textField.text = self.getPreference(section, key);
        textField.delegate = self;
        textField.returnKeyType = UIReturnKeyDone;
        objc_setAssociatedObject(textField, @"section", section, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textField, @"key", key, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(textField, @"item", item, OBJC_ASSOCIATION_ASSIGN);
        [cell setCustomAccessoryView:textField];
    }
    
    // 检查启用条件
    BOOL(^checkEnable)(void) = item[@"enableCondition"];
    cell.userInteractionEnabled = !checkEnable || checkEnable();
    cell.contentView.alpha = cell.userInteractionEnabled ? 1.0 : 0.5;
    
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)elementKind atIndexPath:(NSIndexPath *)indexPath {
    if ([elementKind isEqualToString:UICollectionView.elementKindSectionHeader]) {
        PLCardSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:elementKind withReuseIdentifier:@"SectionHeader" forIndexPath:indexPath];
        
        if (self.prefSections && indexPath.section < self.prefSections.count) {
            NSString *key = self.prefSections[indexPath.section];
            header.titleLabel.text = localize(([NSString stringWithFormat:@"preference.section.%@", key]), nil);
        } else {
            header.titleLabel.text = nil;
        }
        
        return header;
    }
    return nil;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    
    if (item[@"type"] == self.typeButton) {
        [self handleButtonAction:item];
    } else if (item[@"type"] == self.typeChildPane) {
        [self openChildPane:item];
    } else if (item[@"type"] == self.typePickField) {
        [self openPicker:item];
    }
}

#pragma mark - Control event handlers

- (void)toggleDetailVisibility {
    self.prefDetailVisible = !self.prefDetailVisible;
    if (_tableView) {
        [_tableView reloadData];
    }
    if (_collectionView) {
        [_collectionView reloadData];
    }
}

- (void)sliderMoved:(DBNumberedSlider *)sender {
    [self checkWarn:sender];
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = objc_getAssociatedObject(sender, @"key");

    sender.value = (int)sender.value;
    self.setPreference(section, key, @(sender.value));
}

- (void)switchChanged:(UISwitch *)sender {
    [self checkWarn:sender];
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    NSString *section = objc_getAssociatedObject(sender, @"section");
    NSString *key = item[@"key"];

    NSArray *customSwitchValue = item[@"customSwitchValue"];
    self.setPreference(section, key, customSwitchValue ?
        customSwitchValue[sender.isOn] : @(sender.isOn));

    void(^invokeAction)(BOOL) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.isOn);
    }

    if ([item[@"requestReload"] boolValue]) {
        if (_tableView) [_tableView reloadData];
        if (_collectionView) [_collectionView reloadData];
    }
}

#pragma mark - Helper methods

- (void)handleButtonAction:(NSDictionary *)item {
    void(^invokeAction)(void) = item[@"action"];
    NSString *key = item[@"key"];
    
    if ([item[@"hasPrompt"] boolValue]) {
        NSString *title = localize((item[@"promptTitle"] ? item[@"promptTitle"] : key), nil);
        NSString *message = localize((item[@"promptMessage"] ? item[@"promptMessage"] :
            [NSString stringWithFormat:@"preference.prompt.%@", key]), nil);
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (invokeAction) invokeAction();
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (invokeAction) {
        invokeAction();
    }
}

- (void)openChildPane:(NSDictionary *)item {
    UIViewController *vc = [item[@"class"] new];
    if ([item[@"canDismissWithSwipe"] boolValue]) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.navigationBar.prefersLargeTitles = YES;
        nav.modalInPresentation = YES;
        [self.navigationController presentViewController:nav animated:YES completion:nil];
    }
}

- (void)openPicker:(NSDictionary *)item {
    NSString *key = item[@"key"];
    NSString *section = objc_getAssociatedObject(item, @"section") ?: @"";
    NSArray *values = item[@"values"];
    NSArray *titles = item[@"titles"];
    id currentValue = self.getPreference(section, key);
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (int i = 0; i < values.count; i++) {
        NSString *title = titles ? titles[i] : values[i];
        id value = values[i];
        BOOL isSelected = [currentValue isEqual:value];
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.setPreference(section, key, value);
            if (_tableView) [_tableView reloadData];
            if (_collectionView) [_collectionView reloadData];
        }];
        if (isSelected) {
            [action setValue:@YES forKey:@"checked"];
        }
        [alert addAction:action];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = self.view.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Original methods

- (void)initViewCreation {
    __weak PLPrefTableViewController *weakSelf = self;

    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        BOOL destructive = [item[@"destructive"] boolValue];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.textColor = destructive ? UIColor.systemRedColor : weakSelf.view.tintColor;
    };

    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeTextField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        Class cls = item[@"customClass"];
        if (!cls) cls = UITextField.class;
        UITextField *view = [[cls alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:view action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
        view.adjustsFontSizeToFitWidth = YES;
        view.autocorrectionType = UITextAutocorrectionTypeNo;
        view.autocapitalizationType = UITextCapitilizationTypeNone;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        view.delegate = weakSelf;
        view.returnKeyType = UIReturnKeyDone;
        view.textAlignment = NSTextAlignmentRight;
        view.placeholder = localize((item[@"placeholder"] ? item[@"placeholder"] :
            [NSString stringWithFormat:@"preference.placeholder.%@", key]), nil);
        view.text = weakSelf.getPreference(section, key);
        cell.accessoryView = view;
    };

    self.typePickField = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        id value = weakSelf.getPreference(section, key);
        if ([value isKindOfClass:[NSString class]]) {
            cell.detailTextLabel.text = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            cell.detailTextLabel.text = [value boolValue] ? @"YES" : @"NO";
        } else {
            cell.detailTextLabel.text = [value description];
        }
    };

    self.typeSlider = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        DBNumberedSlider *view = [[DBNumberedSlider alloc] initWithFrame:CGRectMake(0, 0, cell.bounds.size.width / 2.1, cell.bounds.size.height)];
        [view addTarget:weakSelf action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin;
        view.minimumValue = [item[@"min"] intValue];
        view.maximumValue = [item[@"max"] intValue];
        view.continuous = YES;
        view.value = [weakSelf.getPreference(section, key) intValue];
        cell.accessoryView = view;
    };

    self.typeSwitch = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISwitch *view = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [view setOn:[weakSelf.getPreference(section, key) boolValue] animated:NO];
        } else {
            [view setOn:[weakSelf.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [view addTarget:weakSelf action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    };
}

- (void)showAlertOnView:(UIView *)view title:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    alert.popoverPresentationController.sourceView = view;
    alert.popoverPresentationController.sourceRect = view.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:ok];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkWarn:(UIView *)view {
    NSDictionary *item = objc_getAssociatedObject(view, @"item");
    NSString *key = item[@"key"];

    BOOL(^isWarnable)(UIView *) = item[@"warnCondition"];
    NSString *warnKey = item[@"warnKey"];
    if (isWarnable && isWarnable(view) && (!warnKey || [self.getPreference(@"warnings", warnKey) boolValue])) {
        if (warnKey) {
            self.setPreference(@"warnings", warnKey, @NO);
        }

        NSString *message = localize(([NSString stringWithFormat:@"preference.warn.%@", key]), nil);
        [self showAlertOnView:view title:localize(@"Warning", nil) message:message];
    }
}

- (void)tableView:(UITableView *)tableView invokeActionWithPromptAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    [self handleButtonAction:item];
}

- (void)tableView:(UITableView *)tableView openChildPaneAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    [self openChildPane:item];
}

- (void)tableView:(UITableView *)tableView openPickerAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    objc_setAssociatedObject(item, "section", self.prefSections[indexPath.section], OBJC_ASSOCIATION_ASSIGN);
    [self openPicker:item];
}

#pragma mark - UITextFieldDelegate

- (void)textFieldDidEndEditing:(UITextField *)textField {
    NSString *section = objc_getAssociatedObject(textField, @"section");
    NSString *key = objc_getAssociatedObject(textField, @"key");
    NSDictionary *item = objc_getAssociatedObject(textField, @"item");
    
    self.setPreference(section, key, textField.text);
    
    void(^invokeAction)(NSString *) = item[@"action"];
    if (invokeAction) {
        invokeAction(textField.text);
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - UIContextMenuInteractionDelegate

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3;
    return style;
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end