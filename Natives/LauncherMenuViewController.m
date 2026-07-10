#import "LauncherMenuViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "utils.h"

@interface LauncherMenuViewController ()

@property(nonatomic, strong) UIView *sidebarView;
@property(nonatomic, strong) UIStackView *menuStackView;
@property(nonatomic, strong) NSArray<NSDictionary *> *menuItems;
@property(nonatomic, assign) NSInteger selectedIndex;

@end

@implementation LauncherMenuViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 监听外观变更（字体颜色变化时刷新菜单按钮颜色）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // 菜单项配置
    // 原 case 3（当前版本设置）与 case 2（版本管理）功能重合，合并到 case 2
    // case 3 改为"控制设置"（CustomControlsViewController），原右侧面板的"编辑控件"挪到这里
    self.menuItems = @[
        @{@"icon": @"house.fill", @"title": @" ", @"index": @0},
        @{@"icon": @"arrow.down.circle.fill", @"title": @" ", @"index": @1},
        @{@"icon": @"puzzlepiece.fill", @"title": @" ", @"index": @2},
        @{@"icon": @"gamecontroller.fill", @"title": @" ", @"index": @3},
        @{@"icon": @"gearshape.fill", @"title": @" ", @"index": @4}
    ];
    
    self.selectedIndex = 0;
    
    [self setupSidebar];
}

#pragma mark - UI Setup

- (void)setupSidebar {
    self.sidebarView = [[UIView alloc] init];
    self.sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.sidebarView];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sidebarView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // 创建垂直均分的 UIStackView，替代固定偏移布局。
    // 之前用 startY=60 + 固定间距 15，5 个按钮总高 370pt，在 iPhone 横屏（卡片高度不足）
    // 时第 5 个按钮（设置）被卡片 masksToBounds 裁剪，且按钮只锚定 top 无 bottom 约束，
    // 下方留出大块空白加剧"下面空隙大"的观感。
    // 改用 UIStackView EqualSpacing 让按钮在可用空间内垂直均匀分布，上下留白相同，
    // 无论卡片高度如何都能完整显示所有按钮，且消除固定 startY 导致的下方空白。
    self.menuStackView = [[UIStackView alloc] init];
    self.menuStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuStackView.axis = UILayoutConstraintAxisVertical;
    self.menuStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.menuStackView.alignment = UIStackViewAlignmentCenter;
    self.menuStackView.spacing = 8;
    [self.sidebarView addSubview:self.menuStackView];

    CGFloat buttonSize = 50;
    for (NSInteger i = 0; i < self.menuItems.count; i++) {
        NSDictionary *item = self.menuItems[i];
        UIButton *btn = [self createMenuButtonWithItem:item index:i];
        [self.menuStackView addArrangedSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:buttonSize],
            [btn.heightAnchor constraintEqualToConstant:buttonSize]
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.menuStackView.leadingAnchor constraintEqualToAnchor:self.sidebarView.leadingAnchor],
        [self.menuStackView.trailingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [self.menuStackView.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:8],
        [self.menuStackView.bottomAnchor constraintEqualToAnchor:self.sidebarView.bottomAnchor constant:-8],
        [self.menuStackView.centerXAnchor constraintEqualToAnchor:self.sidebarView.centerXAnchor]
    ]];
}

- (UIButton *)createMenuButtonWithItem:(NSDictionary *)item index:(NSInteger)index {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = index;

    // 设置图标
    UIImage *icon = [UIImage systemImageNamed:item[@"icon"]];
    [btn setImage:icon forState:UIControlStateNormal];

    // 设置颜色 - 选中项高亮
    // 支持自定义字体颜色：用户在设置中配置 general.text_color 后，
    // 未选中项使用自定义颜色，选中项保持高亮蓝色
    UIColor *normalColor = [self menuNormalColor];
    if (index == self.selectedIndex) {
        btn.tintColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    } else {
        btn.tintColor = normalColor;
    }

    // 设置标题（在图标下方）
    btn.titleLabel.font = [UIFont systemFontOfSize:10];
    [btn setTitle:item[@"title"] forState:UIControlStateNormal];
    [btn setTitleColor:(index == self.selectedIndex) ? [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0] : normalColor forState:UIControlStateNormal];
    
    // 垂直布局：图标在上，文字在下
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    btn.titleEdgeInsets = UIEdgeInsetsMake(30, -30, 0, 0);
    btn.imageEdgeInsets = UIEdgeInsetsMake(-10, 0, 0, 0);
    
    [btn addTarget:self action:@selector(menuButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    // 统一圆角：防御性设置 10pt，避免后续给选中态加背景高亮时出现直角方块
    btn.layer.cornerRadius = 10;
    btn.layer.masksToBounds = YES;

    return btn;
}

#pragma mark - Actions

- (void)menuButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;
    
    // 更新选中状态
    self.selectedIndex = index;
    [self updateButtonColors];
    
    // 回调
    NSString *title = self.menuItems[index][@"title"];
    if (self.onMenuItemSelected) {
        self.onMenuItemSelected(index, title);
    }
    
    // 处理导航
    [self handleMenuSelection:index];
}

- (void)updateButtonColors {
    UIColor *normalColor = [self menuNormalColor];
    // 按钮现在在 menuStackView.arrangedSubviews 中（UIStackView 重构后）
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            NSInteger index = btn.tag;

            if (index == self.selectedIndex) {
                btn.tintColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
                [btn setTitleColor:[UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0] forState:UIControlStateNormal];
            } else {
                btn.tintColor = normalColor;
                [btn setTitleColor:normalColor forState:UIControlStateNormal];
            }
        }
    }
}

// 字体颜色变更时刷新所有菜单按钮
- (void)applyCustomAppearance {
    [self updateButtonColors];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 未选中菜单项的颜色：优先使用用户自定义的 general.text_color，否则默认 systemGray
- (UIColor *)menuNormalColor {
    NSString *hex = getPrefObject(@"general.text_color");
    if (hex.length > 0) {
        UIColor *custom = [self colorFromHexString:hex];
        if (custom) return custom;
    }
    return [UIColor systemGrayColor];
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int r, g, b, a = 255;
    if (hex.length == 6) {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        b = r & 0xFF;
        g = (r >> 8) & 0xFF;
        r = (r >> 16) & 0xFF;
    } else {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        a = r & 0xFF;
        b = (r >> 8) & 0xFF;
        g = (r >> 16) & 0xFF;
        r = (r >> 24) & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

- (void)handleMenuSelection:(NSInteger)index {
    switch (index) {
        case 0: // 主页
            // 通知父控制器切换到新闻页
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
            break;

        case 1: // 下载
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
            break;

        case 2: // 版本管理（合并了原"当前版本设置"功能）
            [self showVersionManager];
            break;

        case 3: // 控制设置（原右侧面板"编辑控件"挪到这里）
            [self showControlSettings];
            break;

        case 4: // 设置
            [self showSettings];
            break;
    }
}

- (void)showVersionManager {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)showControlSettings {
    // 发送通知让 LauncherRootViewController 显示控制设置
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowControlSettings" object:nil];
}

- (void)showSettings {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowSettings" object:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    // 账户信息在右侧面板显示，这里不需要处理
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
