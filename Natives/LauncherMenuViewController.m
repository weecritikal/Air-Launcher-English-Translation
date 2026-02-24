#import "LauncherMenuViewController.h"
#import "LauncherPreferencesViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "utils.h"

@interface LauncherMenuViewController ()

@property(nonatomic, strong) UIView *sidebarView;
@property(nonatomic, strong) NSArray<NSDictionary *> *menuItems;
@property(nonatomic, assign) NSInteger selectedIndex;

@end

@implementation LauncherMenuViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    // 菜单项配置
    self.menuItems = @[
        @{@"icon": @"house.fill", @"title": @" ", @"index": @0},
        @{@"icon": @"arrow.down.circle.fill", @"title": @" ", @"index": @1},
        @{@"icon": @"puzzlepiece.fill", @"title": @" ", @"index": @2},
        @{@"icon": @"paintbrush.fill", @"title": @" ", @"index": @3},
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
    
    // 创建菜单按钮
    CGFloat buttonSize = 50;
    CGFloat spacing = 15;
    CGFloat startY = 60;
    
    for (NSInteger i = 0; i < self.menuItems.count; i++) {
        NSDictionary *item = self.menuItems[i];
        UIButton *btn = [self createMenuButtonWithItem:item index:i];
        [self.sidebarView addSubview:btn];
        
        [NSLayoutConstraint activateConstraints:@[
            [btn.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:startY + i * (buttonSize + spacing)],
            [btn.centerXAnchor constraintEqualToAnchor:self.sidebarView.centerXAnchor],
            [btn.widthAnchor constraintEqualToConstant:buttonSize],
            [btn.heightAnchor constraintEqualToConstant:buttonSize]
        ]];
    }
}

- (UIButton *)createMenuButtonWithItem:(NSDictionary *)item index:(NSInteger)index {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = index;
    
    // 设置图标
    UIImage *icon = [UIImage systemImageNamed:item[@"icon"]];
    [btn setImage:icon forState:UIControlStateNormal];
    
    // 设置颜色 - 选中项高亮
    if (index == self.selectedIndex) {
        btn.tintColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    } else {
        btn.tintColor = [UIColor systemGrayColor];
    }
    
    // 设置标题（在图标下方）
    btn.titleLabel.font = [UIFont systemFontOfSize:10];
    [btn setTitle:item[@"title"] forState:UIControlStateNormal];
    [btn setTitleColor:(index == self.selectedIndex) ? [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0] : [UIColor systemGrayColor] forState:UIControlStateNormal];
    
    // 垂直布局：图标在上，文字在下
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    btn.titleEdgeInsets = UIEdgeInsetsMake(30, -30, 0, 0);
    btn.imageEdgeInsets = UIEdgeInsetsMake(-10, 0, 0, 0);
    
    [btn addTarget:self action:@selector(menuButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    
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
    for (UIView *view in self.sidebarView.subviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            NSInteger index = btn.tag;
            
            if (index == self.selectedIndex) {
                btn.tintColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
                [btn setTitleColor:[UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0] forState:UIControlStateNormal];
            } else {
                btn.tintColor = [UIColor systemGrayColor];
                [btn setTitleColor:[UIColor systemGrayColor] forState:UIControlStateNormal];
            }
        }
    }
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
            
        case 2: // 版本管理
            [self showVersionManager];
            break;
            
        case 3: // 当前版本设置
            [self showCurrentVersionSettings];
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

- (void)showCurrentVersionSettings {
    NSString *currentProfile = PLProfiles.current.selectedProfileName;
    if (!currentProfile) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                       message:@"请先选择一个版本"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileSettings" object:currentProfile];
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
