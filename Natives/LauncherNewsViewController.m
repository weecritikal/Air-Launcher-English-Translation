#import "LauncherNewsViewController.h"
#import "authenticator/BaseAuthenticator.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "ios_uikit_bridge.h"

@interface LauncherNewsViewController ()

@property(nonatomic, strong) UIImageView *skinImageView;
@property(nonatomic, strong) UILabel *welcomeLabel;
@property(nonatomic, strong) UILabel *versionLabel;
@property(nonatomic, strong) UIView *skinContainer;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIActivityIndicatorView *loadingIndicator;

@end

@implementation LauncherNewsViewController

- (id)init {
    self = [super init];
    self.title = @"主页";
    return self;
}

- (NSString *)imageName {
    return @"MenuNews";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // FCL Style: Transparent background
    self.view.backgroundColor = [UIColor clearColor];
    
    [self setupUI];
    [self updateSkinDisplay];
    [self checkMinecraftVersions];
    
    // 监听账户变化通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateSkinDisplay)
                                                 name:@"AccountChanged"
                                               object:nil];
    
    // FCL Style: Hide navigation bar in split view
    self.navigationController.navigationBarHidden = YES;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupUI {
    // 皮肤容器
    self.skinContainer = [[UIView alloc] init];
    self.skinContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.skinContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.skinContainer];
    
    // 欢迎标签
    self.welcomeLabel = [[UILabel alloc] init];
    self.welcomeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.welcomeLabel.font = [UIFont boldSystemFontOfSize:28];
    self.welcomeLabel.textColor = [UIColor labelColor];
    self.welcomeLabel.textAlignment = NSTextAlignmentCenter;
    self.welcomeLabel.text = @"欢迎";
    [self.view addSubview:self.welcomeLabel];
    
    // 版本标签
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:14];
    self.versionLabel.textColor = [UIColor secondaryLabelColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.text = @"Amethyst iOS Remastered";
    [self.view addSubview:self.versionLabel];
    
    // 皮肤图片视图
    self.skinImageView = [[UIImageView alloc] init];
    self.skinImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.skinImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.skinImageView.backgroundColor = [UIColor clearColor];
    [self.skinContainer addSubview:self.skinImageView];
    
    // 状态标签
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    [self.view addSubview:self.statusLabel];
    
    // 加载指示器
    self.loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingIndicator.color = [UIColor whiteColor];
    [self.view addSubview:self.loadingIndicator];
    
    // 约束
    [NSLayoutConstraint activateConstraints:@[
        // 欢迎标签
        [self.welcomeLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:40],
        [self.welcomeLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        
        // 版本标签
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.welcomeLabel.bottomAnchor constant:8],
        [self.versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        
        // 皮肤容器
        [self.skinContainer.topAnchor constraintEqualToAnchor:self.versionLabel.bottomAnchor constant:20],
        [self.skinContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.skinContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.skinContainer.heightAnchor constraintEqualToConstant:250],
        
        // 皮肤图片
        [self.skinImageView.centerXAnchor constraintEqualToAnchor:self.skinContainer.centerXAnchor],
        [self.skinImageView.centerYAnchor constraintEqualToAnchor:self.skinContainer.centerYAnchor],
        [self.skinImageView.widthAnchor constraintEqualToConstant:150],
        [self.skinImageView.heightAnchor constraintEqualToConstant:250],
        
        // 状态标签
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.skinContainer.bottomAnchor constant:20],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        
        // 加载指示器
        [self.loadingIndicator.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor]
    ]];
}

- (void)updateSkinDisplay {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.welcomeLabel.text = [NSString stringWithFormat:@"欢迎, %@", username];
        }
        
        // 加载皮肤
        NSString *uuid = currentAuth.authData[@"uuid"];
        if (uuid) {
            [self loadSkinForUUID:uuid];
        } else {
            // 显示默认皮肤
            [self loadDefaultSkin];
        }
    } else {
        self.welcomeLabel.text = @"欢迎";
        [self loadDefaultSkin];
    }
}

- (void)loadSkinForUUID:(NSString *)uuid {
    // 从Mojang API获取皮肤
    NSString *skinURL = [NSString stringWithFormat:@"https://crafatar.com/renders/body/%@?overlay", uuid];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:skinURL]];
        if (imageData) {
            UIImage *skinImage = [UIImage imageWithData:imageData];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (skinImage) {
                    self.skinImageView.image = skinImage;
                } else {
                    [self loadDefaultSkin];
                }
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self loadDefaultSkin];
            });
        }
    });
}

- (void)loadDefaultSkin {
    // 返回默认史蒂夫皮肤
    NSString *steveSkinURL = @"https://crafatar.com/renders/body/8667ba71b85a4004af54457a9734eed7?overlay";
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:steveSkinURL]];
        if (imageData) {
            UIImage *steveSkin = [UIImage imageWithData:imageData];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (steveSkin) {
                    self.skinImageView.image = steveSkin;
                } else {
                    self.skinImageView.image = [UIImage systemImageNamed:@"person.fill"];
                }
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.skinImageView.image = [UIImage systemImageNamed:@"person.fill"];
            });
        }
    });
}

- (void)checkMinecraftVersions {
    self.statusLabel.text = @"正在检测 Minecraft 版本...";
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
                if (json) {
                    NSDictionary *latest = json[@"latest"];
                    NSString *releaseVersion = latest[@"release"];
                    NSString *snapshotVersion = latest[@"snapshot"];
                    
                    self.statusLabel.text = [NSString stringWithFormat:@"最新正式版: %@\n最新测试版: %@", releaseVersion, snapshotVersion];
                } else {
                    self.statusLabel.text = @"版本检测失败";
                }
            } else {
                self.statusLabel.text = @"无法连接到版本服务器";
            }
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
