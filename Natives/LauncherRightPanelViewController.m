#import "LauncherRightPanelViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherProfilesViewController.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// 添加 C 函数声明 - 这些函数在 LauncherPreferences.m 或其他地方定义
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, int value);

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate>

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;

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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAccountInfo];
    [self updateVersionInfo];
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
    self.avatarImageView.layer.cornerRadius = 40;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    self.avatarImageView.tintColor = [UIColor systemGrayColor];
    self.avatarImageView.userInteractionEnabled = YES;
    [self.avatarImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(selectAccount:)]];
    [self.view addSubview:self.avatarImageView];
    
    // 用户名标签
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:16];
    self.usernameLabel.textColor = [UIColor labelColor];
    self.usernameLabel.textAlignment = NSTextAlignmentCenter;
    self.usernameLabel.text = @"未登录";
    [self.view addSubview:self.usernameLabel];
    
    // 版本标签
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:13];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.text = @"未选择版本";
    [self.view addSubview:self.versionLabel];
    
    // 启动游戏按钮
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:@"启动游戏" forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.launchButton.backgroundColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    self.launchButton.layer.cornerRadius = 12;
    self.launchButton.layer.masksToBounds = YES;
    [self.launchButton addTarget:self action:@selector(launchGame) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchButton];
    
    // 管理版本按钮
    self.manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.manageVersionBtn setTitle:@"管理版本" forState:UIControlStateNormal];
    [self.manageVersionBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.manageVersionBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.manageVersionBtn.layer.cornerRadius = 8;
    [self.manageVersionBtn addTarget:self action:@selector(showVersionManager) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.manageVersionBtn];
    
    // 执行JAR按钮
    self.executeJarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeJarBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeJarBtn setTitle:@"执行Jar" forState:UIControlStateNormal];
    [self.executeJarBtn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.executeJarBtn.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
    self.executeJarBtn.layer.cornerRadius = 8;
    [self.executeJarBtn addTarget:self action:@selector(executeJar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.executeJarBtn];
    
    // 约束
    [NSLayoutConstraint activateConstraints:@[
        // 头像
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:30],
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:80],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:80],
        
        // 用户名
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:12],
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        
        // 版本
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:4],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        
        // 执行JAR按钮 (最底部)
        [self.executeJarBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [self.executeJarBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.executeJarBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.executeJarBtn.heightAnchor constraintEqualToConstant:40],
        
        // 管理版本按钮
        [self.manageVersionBtn.bottomAnchor constraintEqualToAnchor:self.executeJarBtn.topAnchor constant:-8],
        [self.manageVersionBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.manageVersionBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.manageVersionBtn.heightAnchor constraintEqualToConstant:40],
        
        // 启动按钮
        [self.launchButton.bottomAnchor constraintEqualToAnchor:self.manageVersionBtn.topAnchor constant:-16],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.launchButton.heightAnchor constraintEqualToConstant:50]
    ]];
}

#pragma mark - Actions

- (void)selectAccount:(UITapGestureRecognizer *)gesture {
    AccountListViewController *vc = [[AccountListViewController alloc] init];
    vc.whenItemSelected = ^void() {
        [self updateAccountInfo];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)showVersionManager {
    LauncherProfilesViewController *vc = [[LauncherProfilesViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)executeJar {
    // 执行JAR功能 - 打开文件选择器选择JAR文件
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"com.sun.java-archive"]]];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count > 0) {
        NSURL *jarURL = urls[0];
        // 调用LauncherNavigationController的enterModInstaller方法
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ExecuteJarFile" object:jarURL];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

- (void)launchGame {
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
    
    // 加载版本元数据
    [self loadVersionMetadataAndLaunch:selectedProfile];
}

- (void)loadVersionMetadataAndLaunch:(NSString *)profileName {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 获取版本元数据
        NSString *versionId = PLProfiles.current.profiles[profileName][@"lastVersionId"];
        if (!versionId) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"无法获取版本信息"];
            });
            return;
        }
        
        // 从Mojang API获取版本详情
        NSURL *url = [NSURL URLWithString:@"https://launchermeta.mojang.com/mc/game/version_manifest.json"];
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (!data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"无法连接到版本服务器"];
            });
            return;
        }
        
        NSError *error;
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!manifest) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"版本数据解析失败"];
            });
            return;
        }
        
        // 查找版本URL
        NSString *versionUrl = nil;
        for (NSDictionary *version in manifest[@"versions"]) {
            if ([version[@"id"] isEqualToString:versionId]) {
                versionUrl = version[@"url"];
                break;
            }
        }
        
        if (!versionUrl) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"找不到版本信息"];
            });
            return;
        }
        
        // 获取版本详情
        NSData *versionData = [NSData dataWithContentsOfURL:[NSURL URLWithString:versionUrl]];
        if (!versionData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"无法获取版本详情"];
            });
            return;
        }
        
        NSDictionary *versionInfo = [NSJSONSerialization JSONObjectWithData:versionData options:0 error:&error];
        if (!versionInfo) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"版本详情解析失败"];
            });
            return;
        }
        
        // 构建metadata
        NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
        metadata[@"id"] = versionId;
        metadata[@"type"] = versionInfo[@"type"];
        metadata[@"mainClass"] = versionInfo[@"mainClass"];
        metadata[@"arguments"] = versionInfo[@"arguments"];
        metadata[@"assetIndex"] = versionInfo[@"assetIndex"];
        metadata[@"downloads"] = versionInfo[@"downloads"];
        metadata[@"libraries"] = versionInfo[@"libraries"];
        metadata[@"logging"] = versionInfo[@"logging"];
        metadata[@"minecraftArguments"] = versionInfo[@"minecraftArguments"];
        metadata[@"releaseTime"] = versionInfo[@"releaseTime"];
        metadata[@"time"] = versionInfo[@"time"];
        
        // 设置Java版本
        NSDictionary *javaVersion = versionInfo[@"javaVersion"];
        if (javaVersion) {
            metadata[@"javaVersion"] = javaVersion;
        } else {
            // 默认Java 8
            metadata[@"javaVersion"] = @{@"majorVersion": @8, @"version": @"1.8"};
        }
        
        // 获取版本特定设置
        NSDictionary *profile = PLProfiles.current.profiles[profileName];
        
        // 应用渲染器设置
        NSString *renderer = profile[@"renderer"] ?: @"auto";
        if (![renderer isEqualToString:@"auto"]) {
            setPrefString(@"video.renderer", renderer);
        }
        
        // 应用Java版本设置
        NSString *javaVer = profile[@"javaVersion"] ?: @"auto";
        if (![javaVer isEqualToString:@"auto"]) {
            setPrefString(@"java.java_version", javaVer);
        }
        
        // 应用内存设置
        NSInteger allocatedMemory = [profile[@"allocatedMemory"] integerValue];
        if (allocatedMemory > 0) {
            setPrefInt(@"general.ram_allocation", (int)allocatedMemory);
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // 启动游戏
            SurfaceViewController *gameVC = [[SurfaceViewController alloc] initWithMetadata:metadata];
            gameVC.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:gameVC animated:YES completion:nil];
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
        
        // 加载头像
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
    } else {
        self.usernameLabel.text = @"未登录";
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    }
}

- (void)updateVersionInfo {
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (selectedProfile) {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfile];
        if (profile) {
            NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
            self.versionLabel.text = versionId;
        }
    } else {
        self.versionLabel.text = @"未选择版本";
    }
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
