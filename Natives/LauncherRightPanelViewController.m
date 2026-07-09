#import "LauncherRightPanelViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherProfilesViewController.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "JavaGUIViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressViewController.h"
#import "DownloadTaskManager.h"
#import "ALTServerConnection.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AvatarManager.h"
#import "ImageCropperViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/time.h>

// 添加 C 函数声明 - 这些函数在 LauncherPreferences.m 或其他地方定义
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, NSInteger value);

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;
// JIT 状态指示标签（启动游戏按钮上方）
@property(nonatomic, strong) UILabel *jitStatusLabel;

// 下载相关属性
@property(nonatomic, strong) MinecraftResourceDownloadTask *task;
@property(nonatomic, strong) DownloadProgressViewController *progressVC;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UILabel *progressLabel;

@end

@implementation LauncherRightPanelViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    [self setupUI];
    [self updateAccountInfo];
    [self updateVersionInfo];
    
    // 监听账户信息更新通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAccountInfo)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];
    // 监听版本/配置切换通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVersionInfo)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    // 监听统一下载任务聚合状态变化，以更新启动按钮
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateLaunchButtonState)
                                                 name:DownloadTaskManagerAggregateStateDidChangeNotification
                                               object:nil];

    // 监听启动器外观变化（自定义字体/卡片颜色），刷新文字颜色
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAccountInfo];
    [self updateVersionInfo];
    [self updateLaunchButtonState];
    [self updateJITStatus];
    [self applyCustomAppearance];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI Setup

- (void)setupUI {
    // 头像
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.cornerRadius = 36;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    self.avatarImageView.tintColor = [UIColor systemGrayColor];
    self.avatarImageView.userInteractionEnabled = YES;
    [self.avatarImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(selectAccount:)]];
    // 长按头像：弹出自定义头像导入/清除菜单
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(showAvatarMenu:)];
    longPress.minimumPressDuration = 0.5;
    [self.avatarImageView addGestureRecognizer:longPress];
    [self.view addSubview:self.avatarImageView];
    
    // 用户名标签
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:16];
    self.usernameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textAlignment = NSTextAlignmentCenter;
    // iPhone 上侧栏宽度更窄，开启字号自适应避免长用户名被截断
    self.usernameLabel.adjustsFontSizeToFitWidth = YES;
    self.usernameLabel.minimumScaleFactor = 0.7;
    self.usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.usernameLabel.text = @"未登录";
    [self.view addSubview:self.usernameLabel];

    // 版本标签
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:13];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.adjustsFontSizeToFitWidth = YES;
    self.versionLabel.minimumScaleFactor = 0.7;
    self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.versionLabel.text = @"未选择版本";
    // FCL 风格：点击版本标签也能弹出选择器
    self.versionLabel.userInteractionEnabled = YES;
    [self.versionLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showVersionPicker)]];
    [self.view addSubview:self.versionLabel];
    
    // 进度标签
    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont systemFontOfSize:12];
    self.progressLabel.textColor = [UIColor secondaryLabelColor];
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.text = @"";
    self.progressLabel.hidden = YES;
    [self.view addSubview:self.progressLabel];
    
    // 进度条
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.hidden = YES;
    [self.view addSubview:self.progressView];
    
    // 启动游戏按钮
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:@"启动游戏" forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    // iPhone 右侧面板更窄：标题字号自适应，避免"下载中..."等长文案被截断
    self.launchButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.launchButton.titleLabel.minimumScaleFactor = 0.6;
    self.launchButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.launchButton.backgroundColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    self.launchButton.layer.cornerRadius = 12;
    self.launchButton.layer.masksToBounds = YES;
    [self.launchButton addTarget:self action:@selector(launchButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchButton];

    // JIT 状态指示标签（位于启动游戏按钮上方）
    self.jitStatusLabel = [[UILabel alloc] init];
    self.jitStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.jitStatusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    self.jitStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.jitStatusLabel.layer.cornerRadius = 8;
    self.jitStatusLabel.layer.masksToBounds = YES;
    self.jitStatusLabel.text = @"JIT: 检测中...";
    [self.view addSubview:self.jitStatusLabel];

    // 选择版本按钮（FCL 风格：右侧版本选择入口；控制设置已挪到左侧菜单 case 3）
    self.manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.manageVersionBtn setTitle:@"选择版本" forState:UIControlStateNormal];
    [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    [self.manageVersionBtn.titleLabel setFont:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]];
    self.manageVersionBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.manageVersionBtn.titleLabel.minimumScaleFactor = 0.7;
    self.manageVersionBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.manageVersionBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.manageVersionBtn.layer.cornerRadius = 8;
    [self.manageVersionBtn addTarget:self action:@selector(showVersionPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.manageVersionBtn];

    // 执行JAR按钮
    self.executeJarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeJarBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeJarBtn setTitle:@"执行Jar" forState:UIControlStateNormal];
    [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.executeJarBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.executeJarBtn.titleLabel.minimumScaleFactor = 0.7;
    self.executeJarBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.executeJarBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.executeJarBtn.layer.cornerRadius = 8;
    [self.executeJarBtn addTarget:self action:@selector(executeJar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.executeJarBtn];
    
    // 约束布局：
    // - 上半部分（头像/用户名/版本/进度）自上而下锚定在顶部
    // - 下半部分（执行Jar/选择版本/JIT/启动按钮）自下而上锚定在底部
    // 这样 JIT 显示和启动游戏按钮位于右侧面板下方，与头像区分离，避免拥挤。
    [NSLayoutConstraint activateConstraints:@[
        // 头像（顶部）
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:72],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:72],

        // 用户名
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:8],
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 版本
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:4],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 进度标签
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:8],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // 进度条
        [self.progressView.topAnchor constraintEqualToAnchor:self.progressLabel.bottomAnchor constant:4],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // ===== 下方按钮区（自下而上锚定到 safeArea 底部）=====
        // 执行Jar 按钮（最底部）
        [self.executeJarBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.executeJarBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.executeJarBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.executeJarBtn.heightAnchor constraintEqualToConstant:38],

        // 管理版本按钮
        [self.manageVersionBtn.bottomAnchor constraintEqualToAnchor:self.executeJarBtn.topAnchor constant:-8],
        [self.manageVersionBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.manageVersionBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.manageVersionBtn.heightAnchor constraintEqualToConstant:38],

        // 启动按钮
        [self.launchButton.bottomAnchor constraintEqualToAnchor:self.manageVersionBtn.topAnchor constant:-8],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.launchButton.heightAnchor constraintEqualToConstant:46],

        // JIT 状态标签（启动按钮上方）
        [self.jitStatusLabel.bottomAnchor constraintEqualToAnchor:self.launchButton.topAnchor constant:-8],
        [self.jitStatusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.jitStatusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.jitStatusLabel.heightAnchor constraintEqualToConstant:20],
    ]];

    // 进度条底部需留出空间避免与下方 JIT 标签重叠（弱约束，允许中间留白）
    [NSLayoutConstraint constraintWithItem:self.jitStatusLabel
                                attribute:NSLayoutAttributeTop
                                relatedBy:NSLayoutRelationGreaterThanOrEqual
                                   toItem:self.progressView
                                attribute:NSLayoutAttributeBottom
                               multiplier:1.0
                                 constant:12].active = YES;
}

#pragma mark - Actions

- (void)selectAccount:(UITapGestureRecognizer *)gesture {
    // FCL 风格：账户管理在中间内容区显示，发送通知让 LauncherRootViewController 切换内容
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
}

#pragma mark - 自定义头像导入

- (void)showAvatarMenu:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:@"未登录" message:@"请先登录账户后再设置自定义头像"];
        return;
    }

    BOOL hasCustom = [[AvatarManager sharedManager] hasCustomAvatarForAccount:accountId];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"自定义头像"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"从相册导入图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self openAvatarImagePicker];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"清除自定义头像" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[AvatarManager sharedManager] removeAvatarForAccount:accountId];
            [self updateAccountInfo];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：用 popover 锚定到头像
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.avatarImageView;
        sheet.popoverPresentationController.sourceRect = self.avatarImageView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)openAvatarImagePicker {
    // 防止重复弹出
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIView *view in window.subviews) {
            if ([view isKindOfClass:[UIImagePickerController class]]) return;
        }
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showAlert:@"错误" message:@"无法获取选中的图片"];
                return;
            }
            // 头像需要正方形，非正方形则裁剪
            if (selectedImage.size.width != selectedImage.size.height) {
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    [weakSelf dismissViewControllerAnimated:YES completion:^{
                        if (croppedImage) {
                            [weakSelf saveAvatarImage:croppedImage];
                        }
                    }];
                };
                // 本 VC 为 child view controller，self.navigationController 可能为 nil，
                // 故用 present 方式呈现裁剪器（包装在 NavigationController 中以保留其导航栏样式）
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cropperVC];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:nav animated:YES completion:nil];
            } else {
                [self saveAvatarImage:selectedImage];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveAvatarImage:(UIImage *)image {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:@"错误" message:@"未登录账户，无法保存头像"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[AvatarManager sharedManager] saveAvatarForAccount:accountId image:image withCompletion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [weakSelf updateAccountInfo];
            } else {
                NSString *msg = error.localizedDescription ?: @"保存头像失败";
                [weakSelf showAlert:@"错误" message:msg];
            }
        });
    }];
}

#pragma mark - JIT 状态显示

- (void)updateJITStatus {
    if (!self.jitStatusLabel) return;
    BOOL enabled = isJITEnabled(NO);
    if (enabled) {
        self.jitStatusLabel.text = @"JIT: 已开启";
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.2 green:0.7 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    } else {
        self.jitStatusLabel.text = @"JIT: 未开启";
        self.jitStatusLabel.textColor = [UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0];
        self.jitStatusLabel.backgroundColor = [[UIColor colorWithRed:0.9 green:0.4 blue:0.3 alpha:1.0] colorWithAlphaComponent:0.15];
    }
}

#pragma mark - 自定义外观（字体颜色）

/// 读取 general.text_color 偏好并应用到右侧面板的主要文字。
/// 卡片背景始终深色（BackgroundManager），用户若设置浅色 card_color 则需同时设置 text_color。
- (void)applyCustomAppearance {
    NSString *hex = getPrefObject(@"general.text_color");
    UIColor *customColor = [self colorFromHexString:hex];
    if (customColor) {
        self.usernameLabel.textColor = customColor;
        self.versionLabel.textColor = [customColor colorWithAlphaComponent:0.75];
        self.progressLabel.textColor = [customColor colorWithAlphaComponent:0.75];
        self.jitStatusLabel.textColor = customColor;
        [self.manageVersionBtn setTitleColor:customColor forState:UIControlStateNormal];
        [self.executeJarBtn setTitleColor:customColor forState:UIControlStateNormal];
    } else {
        // 未设置自定义字体颜色时，恢复系统自适应颜色
        self.usernameLabel.textColor = [UIColor labelColor];
        self.versionLabel.textColor = [UIColor secondaryLabelColor];
        self.progressLabel.textColor = [UIColor secondaryLabelColor];
        [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        // JIT 状态颜色由 updateJITStatus 单独管理，不在此重置
    }
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6 && clean.length != 8) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (clean.length == 6) {
        // RRGGBB
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
        a = 255;
    } else {
        // AARRGGBB
        a = (rgb >> 24) & 0xFF;
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
    }
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

- (void)showVersionPicker {
    // FCL 风格：在右侧面板弹出 ActionSheet 让用户选择已安装的版本
    NSDictionary *profiles = PLProfiles.current.profiles;
    NSArray *sortedNames = [[profiles allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *currentSelected = PLProfiles.current.selectedProfileName;
    
    if (sortedNames.count == 0) {
        [self showAlert:@"暂无已安装的版本" message:@"请先到下载页面安装一个版本"];
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择版本"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *profileName in sortedNames) {
        NSDictionary *profile = profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"";
        // 检测是否启用版本隔离（gameDir != "."）
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        NSMutableString *title = [NSMutableString string];
        if ([profileName isEqualToString:currentSelected]) {
            [title appendString:@"✓ "];
        }
        [title appendString:profileName];
        [title appendFormat:@"  (%@)", versionId];
        if (isolated) {
            [title appendString:@"  · 隔离"];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self selectProfile:profileName];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"管理版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // 跳转到版本管理页面
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad 上 ActionSheet 必须指定 popoverPresentationController
    alert.popoverPresentationController.sourceView = self.manageVersionBtn;
    alert.popoverPresentationController.sourceRect = self.manageVersionBtn.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectProfile:(NSString *)profileName {
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
    // SelectedProfileChanged 通知已由 setSelectedProfileName 内部发送
    [self updateVersionInfo];
}

- (void)showVersionManager {
    // 兼容旧调用方：跳转到版本管理页面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)executeJar {
    // 执行JAR功能 - 打开文件选择器选择JAR文件
    // 使用 asCopy:YES 保证文件被复制到应用沙盒，避免安全作用域 URL 导致 UZKArchive 读取失败
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *jarURL = urls[0];
    [self enterModInstallerWithPath:jarURL.path hitEnterAfterWindowShown:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    // requiredJavaVersion 会读取 JAR 的 MANIFEST.MF 解析主类
    int javaVersion = vc.requiredJavaVersion;
    if (!javaVersion) {
        // JAR 解析失败：vc 还没 present，showDialog 不会显示，这里在 self 上弹明确提示
        [self showAlert:@"无法执行 JAR"
                  message:[NSString stringWithFormat:@"无法解析 JAR 文件：%@\n\n可能原因：\n• 文件不是有效的 Java 归档\n• 缺少 META-INF/MANIFEST.MF\n• 缺少 Main-Class 属性\n• 文件损坏", path.lastPathComponent ?: @""]];
        return;
    }

    // execute_jar 路径：Caciocavallo17 jar 现已统一为 Java 17 编译版本，
    // Java 17/21 均可加载，不再需要强制提升 requiredJavaVersion 到 25。
    // - Java 8 JAR（如 OptiFine 安装器）走 Caciocavallo（非 17）路径，用 Java 8
    // - Java 17+ JAR 走 Caciocavallo17 路径，用 Java 17/21 即可
    // 与 JavaLauncher.m launchJar 分支保持一致。
    int requiredJavaVersion = javaVersion;

    // 预检 execute_jar 标签的 JRE 是否已配置，避免 present 后才发现没 JRE 导致黑屏
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        [self showAlert:@"缺少 Java 运行时"
                  message:[NSString stringWithFormat:@"执行 JAR 需要 Java %d 或更高版本，但未配置对应的运行时。\n\n请到「设置 → 管理运行时」中为「执行 Jar」标签分配一个 Java %d+ 的运行时。", requiredJavaVersion, requiredJavaVersion]];
        return;
    }

    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@ (Java %d, home=%@)", vc.filepath, requiredJavaVersion, javaHome);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

/// 显示简单的提示弹窗
- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Launch Game

- (void)launchButtonTapped {
    if (self.task) {
        if (getPrefBool(@"general.floating_ball_enabled")) {
            // 悬浮球开启时打开统一下载任务界面，不再显示单独进度
            Class tasksVCClass = NSClassFromString(@"DownloadTasksViewController");
            if (tasksVCClass) {
                UIViewController *vc = [[tasksVCClass alloc] init];
                vc.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:vc animated:YES completion:nil];
            }
        } else {
            // 正在下载，显示详情
            if (!self.progressVC) {
                self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
            }
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            [self presentViewController:nav animated:YES completion:nil];
        }
    } else if ([[DownloadTaskManager sharedManager] hasActiveTasks]) {
        // 下载中仍允许启动游戏（不再硬阻断），仅提示用户有进行中的下载。
        // 原实现在此处 return 导致"开了下载球后任意下载未完成就永远无法启动游戏"，
        // 且某些下载任务状态机异常会卡住导致永久无法启动。
        [self showAlert:@"提示" message:@"有下载任务正在进行，启动游戏可能受影响。"];
        [self launchGame];
    } else {
        [self launchGame];
    }
}

- (void)launchGame {
    // 下载任务不再阻断启动。某些下载（如 Mod/光影）与游戏本体启动无依赖关系，
    // 强制等待会造成"启动游戏过慢或无法启动"的体验问题。
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (!currentAuth) {
        [self showAlert:@"请先登录账户"];
        return;
    }

    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (!selectedProfile) {
        [self showAlert:@"请先选择一个版本"];
        return;
    }

    NSString *versionId = PLProfiles.current.profiles[selectedProfile][@"lastVersionId"];
    if (!versionId) {
        [self showAlert:@"无法获取版本信息"];
        return;
    }

    // FCL 风格：记录最后游玩时间戳到 profile，供版本管理页显示
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[selectedProfile] mutableCopy];
    if (profile) {
        profile[@"lastPlayed"] = @([[NSDate date] timeIntervalSince1970]);
        profiles[selectedProfile] = profile;
        [PLProfiles.current save];
    }

    // 设置UI为下载状态
    [self setInteractionEnabled:NO];
    
    // 查找版本对象
    NSDictionary *versionObject = nil;
    
    // 从远程版本列表中查找（通过 LauncherRootViewController 的 remoteVersionList）
    // 由于 remoteVersionList 在 LauncherRootViewController 中，我们需要通过其他方式获取
    // 这里使用通知来请求版本信息
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"versionId"] = versionId;
    userInfo[@"callback"] = ^(NSDictionary *version) {
        if (version) {
            [self startDownloadWithVersion:version profileName:selectedProfile];
        } else {
            // 如果在远程列表中找不到，可能是本地版本
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setInteractionEnabled:YES];
                [self showAlert:@"找不到版本信息，请检查版本是否正确"];
            });
        }
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FindVersionInRemoteList" object:nil userInfo:userInfo];
}

- (void)startDownloadWithVersion:(NSDictionary *)versionObject profileName:(NSString *)profileName {
    self.task = [MinecraftResourceDownloadTask new];
    
    __weak LauncherRightPanelViewController *weakSelf = self;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        weakSelf.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES];
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        
        [weakSelf.task downloadVersion:versionObject];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.progressView.observedProgress = weakSelf.task.progress;
            [weakSelf.task.progress addObserver:weakSelf
                                    forKeyPath:@"fractionCompleted"
                                       options:NSKeyValueObservingOptionInitial
                                       context:ProgressObserverContext];
        });
    });
}

- (void)setInteractionEnabled:(BOOL)enabled {
    self.manageVersionBtn.enabled = enabled;
    self.executeJarBtn.enabled = enabled;

    BOOL showProgressUI = !getPrefBool(@"general.floating_ball_enabled");
    if (enabled) {
        self.progressView.hidden = YES;
        self.progressLabel.hidden = YES;
        self.progressLabel.text = @"";
    } else {
        self.progressView.hidden = !showProgressUI;
        self.progressLabel.hidden = !showProgressUI;
        self.progressLabel.text = showProgressUI ? @"正在准备..." : @"";
    }

    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
    [self updateLaunchButtonState];
}

- (void)updateLaunchButtonState {
    BOOL hasActiveTasks = [[DownloadTaskManager sharedManager] hasActiveTasks];
    BOOL hasAccount = (BaseAuthenticator.current != nil);
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    BOOL hasVersion = selectedProfile && PLProfiles.current.profiles[selectedProfile][@"lastVersionId"] != nil;
    // 下载中不再禁用启动按钮：仅作提示，不阻断启动（避免下载卡住导致永久无法启动）
    BOOL enabled = hasAccount && hasVersion && !self.task;

    self.launchButton.enabled = enabled;
    [self.launchButton setTitle:(hasActiveTasks ? @"启动游戏（下载中）" : @"启动游戏") forState:UIControlStateNormal];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    // 计算下载速度和剩余时间
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL showProgressUI = !getPrefBool(@"general.floating_ball_enabled");
        if (showProgressUI) {
            self.progressLabel.text = progress.localizedAdditionalDescription;
        }

        if (!progress.finished) return;
        
        [self.progressVC dismissViewControllerAnimated:NO completion:nil];
        
        self.progressView.observedProgress = nil;
        
        if (self.task.metadata) {
            // 应用配置特定的设置
            NSString *profileName = PLProfiles.current.selectedProfileName;
            NSDictionary *profile = PLProfiles.current.profiles[profileName];
            
            if (profile) {
                // 应用渲染器设置
                NSString *renderer = profile[@"renderer"] ?: @"auto";
                if (![renderer isEqualToString:@"auto"]) {
                    setPrefString(@"video.renderer", renderer);
                }
                
                // 应用Java版本设置（兼容旧版直装器写入的 NSDictionary 格式）
                id javaVerRaw = profile[@"javaVersion"];
                NSString *javaVer = nil;
                if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
                    id major = javaVerRaw[@"majorVersion"];
                    javaVer = major ? [major description] : @"auto";
                } else if ([javaVerRaw isKindOfClass:[NSString class]]) {
                    javaVer = javaVerRaw;
                } else {
                    javaVer = @"auto";
                }
                if (![javaVer isEqualToString:@"auto"]) {
                    setPrefString(@"java.java_version", javaVer);
                }
                
                // 应用内存设置
                NSInteger allocatedMemory = [profile[@"allocatedMemory"] integerValue];
                if (allocatedMemory > 0) {
                    setPrefInt(@"general.ram_allocation", (int)allocatedMemory);
                }
            }
            
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(self.view.window, self.task.metadata);
            }];
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES];
            // 通知刷新版本列表
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
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
    
    self.progressLabel.text = @"等待 JIT...";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"等待 JIT"
                                                                   message:hasTrollStoreJIT ? @"正在通过 TrollStore 启用 JIT..." : @"请启用 JIT"
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

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.usernameLabel.text = username;
        }

        // 加载头像：本地自定义头像优先，回退到在线 URL
        // 头像文件名使用 accountId（唯一标识），同名账户头像不再冲突
        UIImage *localAvatar = [[AvatarManager sharedManager] avatarForAccount:currentAuth.authData[@"accountId"]];
        if (localAvatar) {
            self.avatarImageView.image = localAvatar;
        } else {
            NSString *avatarURL = currentAuth.authData[@"profilePicURL"];
            if (avatarURL) {
                avatarURL = [avatarURL stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
                    if (imageData) {
                        UIImage *image = [UIImage imageWithData:imageData];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.avatarImageView.image = image;
                        });
                    }
                });
            }
        }
    } else {
        self.usernameLabel.text = @"未登录";
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    }

    [self updateLaunchButtonState];
}

- (void)updateVersionInfo {
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (selectedProfile) {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfile];
        if (profile) {
            NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
            // 显示版本隔离状态：gameDir != "." 表示已隔离
            NSString *gameDir = profile[@"gameDir"] ?: @".";
            BOOL isolated = ![gameDir isEqualToString:@"."];
            if (isolated) {
                self.versionLabel.text = [NSString stringWithFormat:@"%@  · 隔离", versionId];
            } else {
                self.versionLabel.text = versionId;
            }
        }
    } else {
        self.versionLabel.text = @"未选择版本";
    }

    [self updateLaunchButtonState];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end