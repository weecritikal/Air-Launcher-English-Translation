#import "LauncherRightPanelViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherProfilesViewController.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "CustomControlsViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadProgressViewController.h"
#import "ALTServerConnection.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <sys/time.h>

// 添加 C 函数声明 - 这些函数在 LauncherPreferences.m 或其他地方定义
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, NSInteger value);

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate>

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;

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
    self.launchButton.backgroundColor = [UIColor colorWithRed:0.26 green:0.63 blue:0.96 alpha:1.0];
    self.launchButton.layer.cornerRadius = 12;
    self.launchButton.layer.masksToBounds = YES;
    [self.launchButton addTarget:self action:@selector(launchButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchButton];
    
    // 编辑控件按钮
    self.manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.manageVersionBtn setTitle:@"编辑控件" forState:UIControlStateNormal];
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
        
        // 进度标签
        [self.progressLabel.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:8],
        [self.progressLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.progressLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        
        // 进度条
        [self.progressView.topAnchor constraintEqualToAnchor:self.progressLabel.bottomAnchor constant:4],
        [self.progressView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.progressView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        
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
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
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

#pragma mark - Launch Game

- (void)launchButtonTapped {
    if (self.task) {
        // 正在下载，显示详情
        if (!self.progressVC) {
            self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
        }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    } else {
        [self launchGame];
    }
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
    
    NSString *versionId = PLProfiles.current.profiles[selectedProfile][@"lastVersionId"];
    if (!versionId) {
        [self showAlert:@"无法获取版本信息"];
        return;
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
    self.launchButton.enabled = enabled;
    self.manageVersionBtn.enabled = enabled;
    self.executeJarBtn.enabled = enabled;
    
    if (enabled) {
        [self.launchButton setTitle:@"启动游戏" forState:UIControlStateNormal];
        self.progressView.hidden = YES;
        self.progressLabel.hidden = YES;
        self.progressLabel.text = @"";
    } else {
        [self.launchButton setTitle:@"下载中..." forState:UIControlStateNormal];
        self.progressView.hidden = NO;
        self.progressLabel.hidden = NO;
        self.progressLabel.text = @"正在准备...";
    }
    
    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
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
        self.progressLabel.text = progress.localizedAdditionalDescription;
        
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
                                                                   message:hasTrollStoreJIT ? @"正在通过 TrollStore 启用 JIT..." : @"请通过 AltServer 启用 JIT"
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